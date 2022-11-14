using Lux
using Random
using CUDA

# Note: Julia/Lux assume WHCN ordering

function sinusoidal_embedding(
    x::AbstractArray{T,4},
    min_freq::T,
    max_freq::T,
    embedding_dims::Int,
) where {T}
    if size(x)[1:3] != (1, 1, 1)
        throw(DimensionMismatch("Input shape must be (1, 1, 1, batch)"))
    end
    # freqs = exp.(LinRange(log(min_freq), log(max_freq), div(embedding_dims, 2))) # (embedding_dims,)
    # To use LinRange, we need its @adjoint
    # Instead we implement it manually
    lower = log(min_freq)
    upper = log(max_freq)
    n = div(embedding_dims, 2)
    d = (upper - lower) / (n - 1)
    freqs = exp.(lower:d:upper) |> gpu
    @assert length(freqs) == div(embedding_dims, 2)
    @assert size(freqs) == (div(embedding_dims, 2),)

    angular_speeds = reshape(convert(T, 2) * π * freqs, (1, 1, length(freqs), 1))
    @assert size(angular_speeds) == (1, 1, div(embedding_dims, 2), 1)

    embeddings = cat(sin.(angular_speeds .* x), cos.(angular_speeds .* x), dims = 3)
    @assert size(embeddings) == (1, 1, embedding_dims, size(x, 4))

    embeddings
end

function sigmoid(x)
    1 / (1 + exp(-x))
end

function silu(x)
    x * sigmoid(x)
end


function residual_block(in_channels::Int, num_channels::Int)
    if in_channels == num_channels
        first_layer = NoOpLayer()
    else
        first_layer = Conv((3, 3), in_channels => num_channels, pad = SamePad())
    end

    Lux.Chain(
        first_layer,
        Lux.SkipConnection(
            Lux.Chain(
                BatchNorm(num_channels, affine = false, momentum = 0.99),
                Conv((3, 3), num_channels => num_channels, stride = 1, pad = (1, 1)),
                WrappedFunction(Base.Fix1(broadcast, silu)),
                Conv((3, 3), num_channels => num_channels, stride = 1, pad = (1, 1)),
            ),
            +,
        ),
    )
end

struct DownBlock{T1,T2} <: Lux.AbstractExplicitContainerLayer{(:residual_blocks, :maxpool)}
    residual_blocks::T1
    maxpool::T2
end

function DownBlock(in_channels::Int, num_channel::Int, block_depth::Int)
    layers = []
    push!(layers, residual_block(in_channels, num_channel))
    for _ = 2:block_depth
        push!(layers, residual_block(num_channel, num_channel))
    end
    # disable optimizations to keep block index
    residual_blocks = Lux.Chain(layers..., disable_optimizations = true)
    maxpool = MaxPool((2, 2); pad = 0)
    return DownBlock(residual_blocks, maxpool)
end

function (db::DownBlock)(x::AbstractArray{T,4}, ps, st::NamedTuple) where {T}
    skips = ()
    for i = 1:length(db.residual_blocks)
        layer_name = Symbol(:layer_, i)
        x, new_st = db.residual_blocks[i](
            x,
            ps.residual_blocks[layer_name],
            st.residual_blocks[layer_name],
        )
        # push! on vector invokes Zygote error
        skips = (skips..., x)
        Lux.@set! st.residual_blocks[layer_name] = new_st
    end
    x, _ = db.maxpool(x, ps.maxpool, st.maxpool)
    return (x, skips), st
end



struct UpBlock{T1,T2} <: Lux.AbstractExplicitContainerLayer{(:residual_blocks, :upsample)}
    residual_blocks::T1
    upsample::T2
end

function UpBlock(in_channels::Int, num_channel::Int, block_depth::Int)
    layers = []
    push!(layers, residual_block(in_channels + num_channel, num_channel))
    for _ = 2:block_depth
        push!(layers, residual_block(num_channel * 2, num_channel))
    end
    residual_blocks = Lux.Chain(layers..., disable_optimizations = true)
    upsample = Lux.Upsample(:bilinear, scale = 2)
    return UpBlock(residual_blocks, upsample)
end

function (up::UpBlock)(
    x::Tuple{AbstractArray{T,4},NTuple{N,AbstractArray{T,4}}},
    ps,
    st::NamedTuple,
) where {T,N}
    x, skips = x
    x, _ = up.upsample(x, ps.upsample, st.upsample)
    for i = 1:length(up.residual_blocks)
        layer_name = Symbol(:layer_, i)
        x = cat(x, skips[end-i+1], dims = 3) # cat on channel
        x, new_st = up.residual_blocks[i](
            x,
            ps.residual_blocks[layer_name],
            st.residual_blocks[layer_name],
        )
        Lux.@set! st.residual_blocks[layer_name] = new_st
    end

    return x, st
end


struct UNet{T1,T2,T3} <: Lux.AbstractExplicitContainerLayer{(
    :upsample,
    :conv_in,
    :conv_out,
    :down_blocks,
    :residual_blocks,
    :up_blocks,
)}
    upsample::Lux.Upsample
    conv_in::Lux.Conv
    conv_out::Lux.Conv
    down_blocks::T1
    residual_blocks::T2
    up_blocks::T3
    noise_embedding::Any
end

function UNet(
    image_size::Tuple{Int,Int};
    channels = [32, 64, 96, 128],
    block_depth = 2,
    min_freq = 1.0f0,
    max_freq = 1000.0f0,
    embedding_dims = 32,
)
    upsample = Lux.Upsample(:nearest, size = image_size)
    conv_in = Lux.Conv((1, 1), 3 => channels[1])
    conv_out = Lux.Conv((1, 1), channels[1] => 3, init_weight = Lux.zeros32)

    noise_embedding = x -> sinusoidal_embedding(x, min_freq, max_freq, embedding_dims)

    channel_input = embedding_dims + channels[1]

    down_blocks = []
    push!(down_blocks, DownBlock(channel_input, channels[1], block_depth))
    for i = 1:(length(channels)-2)
        push!(down_blocks, DownBlock(channels[i], channels[i+1], block_depth))
    end
    down_blocks = Lux.Chain(down_blocks..., disable_optimizations = true)

    residual_blocks = []
    push!(residual_blocks, residual_block(channels[end-1], channels[end]))
    for _ = 2:block_depth
        push!(residual_blocks, residual_block(channels[end], channels[end]))
    end
    residual_blocks = Lux.Chain(residual_blocks..., disable_optimizations = true)

    reverse!(channels)
    up_blocks =
        [UpBlock(channels[i], channels[i+1], block_depth) for i = 1:(length(channels)-1)]
    up_blocks = Lux.Chain(up_blocks...)


    return UNet(
        upsample,
        conv_in,
        conv_out,
        down_blocks,
        residual_blocks,
        up_blocks,
        noise_embedding,
    )
end

function (unet::UNet)(
    x::Tuple{AbstractArray{T,N},AbstractArray{T,N}},
    ps,
    st::NamedTuple,
) where {T,N}
    noisy_images, noise_variances = x
    @assert length(size(noisy_images)) == 4
    @assert length(size(noise_variances)) == 4
    @assert size(noise_variances)[1:3] == (1, 1, 1)
    @assert size(noisy_images, 4) == size(noise_variances, 4)

    emb = unet.noise_embedding(noise_variances)
    @assert size(emb)[[1, 2, 4]] == (1, 1, size(noise_variances, 4))
    emb, _ = unet.upsample(emb, ps.upsample, st.upsample)
    @assert size(emb)[[1, 2, 4]] ==
            (size(noisy_images, 1), size(noisy_images, 2), size(noise_variances, 4))

    x, new_st = unet.conv_in(noisy_images, ps.conv_in, st.conv_in)
    Lux.@set! st.conv_in = new_st
    @assert size(x)[[1, 2, 4]] ==
            (size(noisy_images, 1), size(noisy_images, 2), size(noisy_images, 4))

    x = cat(x, emb, dims = 3)
    @assert size(x)[[1, 2, 4]] ==
            (size(noisy_images, 1), size(noisy_images, 2), size(noisy_images, 4))

    skips_at_each_stage = ()
    for i = 1:length(unet.down_blocks)
        layer_name = Symbol(:layer_, i)
        (x, skips), new_st =
            unet.down_blocks[i](x, ps.down_blocks[layer_name], st.down_blocks[layer_name])
        Lux.@set! st.down_blocks[layer_name] = new_st
        skips_at_each_stage = (skips_at_each_stage..., skips)
    end

    x, new_st = unet.residual_blocks(x, ps.residual_blocks, st.residual_blocks)
    Lux.@set! st.residual_blocks = new_st

    for i = 1:length(unet.up_blocks)
        layer_name = Symbol(:layer_, i)
        x, new_st = unet.up_blocks[i](
            (x, skips_at_each_stage[end-i+1]),
            ps.up_blocks[layer_name],
            st.up_blocks[layer_name],
        )
        Lux.@set! st.up_blocks[layer_name] = new_st
    end

    x, new_st = unet.conv_out(x, ps.conv_out, st.conv_out)
    Lux.@set! st.conv_out = new_st

    return x, st
end

struct DenoisingDiffusionImplicitModel <:
       Lux.AbstractExplicitContainerLayer{(:unet, :batchnorm)}
    unet::UNet
    batchnorm::Lux.BatchNorm
    min_signal_rate::Any
    max_signal_rate::Any
end

function DenoisingDiffusionImplicitModel(
    image_size::Tuple{Int,Int};
    channels = [32, 64, 96, 128],
    block_depth = 2,
    min_freq = 1.0f0,
    max_freq = 1000.0f0,
    embedding_dims = 32,
    min_signal_rate = 0.02f0,
    max_signal_rate = 0.95f0,
)
    unet = UNet(
        image_size,
        channels = channels,
        block_depth = block_depth,
        min_freq = min_freq,
        max_freq = max_freq,
        embedding_dims = embedding_dims,
    )
    batchnorm = Lux.BatchNorm(3, affine = false, momentum = 0.99, track_stats = true)

    return DenoisingDiffusionImplicitModel(
        unet,
        batchnorm,
        min_signal_rate,
        max_signal_rate,
    )

end

function (ddim::DenoisingDiffusionImplicitModel)(
    x::Tuple{AbstractArray{T,4},AbstractRNG},
    ps,
    st::NamedTuple,
) where {T}
    images, rng = x
    images, new_st = ddim.batchnorm(images, ps.batchnorm, st.batchnorm)
    Lux.@set! st.batchnorm = new_st

    noises = randn(rng, eltype(images), size(images)...) |> gpu

    diffusion_times = rand(rng, eltype(images), 1, 1, 1, size(images)[end]) |> gpu
    noise_rates, signal_rates =
        diffusion_schedules(diffusion_times, ddim.min_signal_rate, ddim.max_signal_rate)

    noisy_images = signal_rates .* images + noise_rates .* noises

    (pred_noises, pred_images), st =
        denoise(ddim, noisy_images, noise_rates, signal_rates, ps, st)

    return (noises, images, pred_noises, pred_images), st
end

function diffusion_schedules(
    diffusion_times::AbstractArray{T,4},
    min_signal_rate,
    max_signal_rate,
) where {T}
    start_angle = acos(max_signal_rate)
    end_angle = acos(min_signal_rate)

    diffusion_angles = start_angle .+ (end_angle - start_angle) * diffusion_times

    signal_rates = cos.(diffusion_angles)
    noise_rates = sin.(diffusion_angles)

    return noise_rates, signal_rates
end

function denoise(
    ddim::DenoisingDiffusionImplicitModel,
    noisy_images::AbstractArray{T,4},
    noise_rates::AbstractArray{T,4},
    signal_rates::AbstractArray{T,4},
    ps,
    st::NamedTuple,
) where {T}
    pred_noises, new_st = ddim.unet((noisy_images, noise_rates .^ 2), ps.unet, st.unet)
    Lux.@set! st.unet = new_st

    pred_images = (noisy_images - pred_noises .* noise_rates) ./ signal_rates

    return (pred_noises, pred_images), st
end

function reverse_diffusion(
    ddim::DenoisingDiffusionImplicitModel,
    initial_noise::AbstractArray{T,4},
    diffusion_steps::Int,
    ps,
    st::NamedTuple;
    save_each_step = false,
) where {T}
    num_images = size(initial_noise)[end]
    step_size = convert(T, 1.0) / diffusion_steps

    next_noisy_images = initial_noise
    pred_images = nothing
    images_each_step = ifelse(save_each_step, [initial_noise], nothing)
    for step = 1:diffusion_steps
        noisy_images = next_noisy_images

        diffusion_times = ones(T, 1, 1, 1, num_images) .- step_size * step |> gpu

        noise_rates, signal_rates =
            diffusion_schedules(diffusion_times, ddim.min_signal_rate, ddim.max_signal_rate)

        (pred_noises, pred_images), _ =
            denoise(ddim, noisy_images, noise_rates, signal_rates, ps, st)

        next_diffusion_times = diffusion_times .- step_size
        next_noise_rates, next_signal_rates = diffusion_schedules(
            next_diffusion_times,
            ddim.min_signal_rate,
            ddim.max_signal_rate,
        )


        next_noisy_images =
            next_signal_rates .* pred_images + next_noise_rates .* pred_noises

        if save_each_step
            push!(images_each_step, pred_images)
        end
    end

    return pred_images, images_each_step
end

function denormalize(
    ddim::DenoisingDiffusionImplicitModel,
    x::AbstractArray{T,4},
    st,
) where {T}
    mean = reshape(st.running_mean, 1, 1, 3, 1)
    var = reshape(st.running_var, 1, 1, 3, 1)
    std = sqrt.(var .+ ddim.batchnorm.epsilon)
    return std .* x .+ mean
end

function generate(
    ddim::DenoisingDiffusionImplicitModel,
    rng::AbstractRNG,
    image_shape::Tuple{Int,Int,Int,Int},
    diffusion_steps::Int,
    ps,
    st::NamedTuple;
    save_each_step = false,
)
    initial_noise = randn(rng, Float32, image_shape...) |> gpu
    generated_images, images_each_step = reverse_diffusion(
        ddim,
        initial_noise,
        diffusion_steps,
        ps,
        st,
        save_each_step = save_each_step,
    )
    generated_images = denormalize(ddim, generated_images, st.batchnorm)
    clamp!(generated_images, 0.0f0, 1.0f0)

    if !isnothing(images_each_step)
        for (i, images) in enumerate(images_each_step)
            images_each_step[i] = denormalize(ddim, images, st.batchnorm)
            clamp!(images_each_step[i], 0.0f0, 1.0f0)
        end
    end
    return generated_images, images_each_step
end