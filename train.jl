using Lux,
    Random,
    Revise,
    Images,
    MLUtils,
    ImageFiltering,
    Interpolations,
    Optimisers,
    Statistics,
    ProgressBars,
    Zygote,
    CUDA,
    BSON,
    Comonicon

include("./model.jl")

#=
Dataset
=#
struct OxfordFlowersDataset
    image_files::Vector{AbstractString}
    preprocess::Any
    use_cache::Bool
    cache::Vector{Union{Nothing,AbstractArray{Float32,3}}}
end

function OxfordFlowersDataset(dirpath::AbstractString, preprocess, use_cache::Bool)
    image_files = joinpath.(dirpath, readdir(dirpath))
    cache = map(x -> nothing, image_files)
    return OxfordFlowersDataset(image_files, preprocess, use_cache, cache)
end

Base.length(ds::OxfordFlowersDataset) = length(ds.image_files)

function Base.getindex(ds::OxfordFlowersDataset, i::Int)
    if ds.use_cache && !isnothing(ds.cache[i])
        return ds.cache[i]
    else
        img = Images.load(ds.image_files[i])
        img = ds.preprocess(img)
        img = permutedims(channelview(img), (2, 3, 1))
        if ds.use_cache
            ds.cache[i] = img
        end
        return Float32.(img)
    end
end


function center_crop(image::Matrix{RGB{T}}) where {T}
    height, width = size(image)
    crop_size = min(height, width)

    x1 = 1 + div((width - crop_size), 2)
    x2 = x1 + crop_size - 1
    y1 = 1 + div((height - crop_size), 2)
    y2 = y1 + crop_size - 1

    return image[y1:y2, x1:x2]
end

function resize(image::Matrix{RGB{T}}, image_size::Tuple{Int,Int}) where {T}
    σ = map((o, n) -> 0.75 * o / n, size(image), image_size)
    kern = KernelFactors.gaussian(σ)
    return imresize(
        imfilter(image, kern, NA()),
        image_size,
        method = Interpolations.Linear(),
    )
end

function preprocess_image(image::Matrix{RGB{T}}, image_size::Tuple{Int,Int}) where {T}
    image = center_crop(image)
    image = resize(image, image_size)
    return image
end

#=
Training utilities
=#
function compute_loss(
    ddim::DenoisingDiffusionImplicitModel,
    images::AbstractArray{T,4},
    rng::AbstractRNG,
    ps,
    st::NamedTuple,
) where {T}
    (noises, images, pred_noises, pred_images), st = ddim((images, rng), ps, st)
    noise_loss = Statistics.mean(abs.(pred_noises - noises))
    image_loss = Statistics.mean(abs.(pred_images - images))
    loss = noise_loss + image_loss
    return loss, st
end

function train_step(
    ddim::DenoisingDiffusionImplicitModel,
    images::AbstractArray{T,4},
    rng::AbstractRNG,
    ps,
    st::NamedTuple,
    opt_st::NamedTuple,
) where {T}
    # what is proper way of taking grads???
    (loss, st), back = Zygote.pullback(p -> compute_loss(ddim, images, rng, p, st), ps)
    gs = back((one(loss), nothing))[1]
    opt_st, ps = Optimisers.update(opt_st, ps, gs)
    return loss, ps, st, opt_st
end

function save_checkpoint(ps, st, opt_st, output_dir, epoch)
    path = joinpath(output_dir, "checkpoint_$(epoch).bson")
    bson(path, Dict(:ps => cpu(ps), :st => cpu(st), :opt_st => cpu(opt_st)))
end

function save_as_png(images::AbstractArray{T,4}, output_dir, epoch) where {T}
    for i = 1:size(images, 4)
        img = @view images[:, :, :, i]
        img = colorview(RGB, permutedims(img, (3, 1, 2)))
        save(joinpath(output_dir, "img_$(i)_epoch$(epoch).png"), img)
    end
end

#=
Main function
=#
@main function main(;
    epochs::Int = 1,
    image_size::Int = 64,
    batchsize::Int = 64,
    learning_rate::Float64 = 1e-3,
    weight_decay::Float64 = 1e-4,
    val_diffusion_steps::Int = 3,
    output_dir::String = "./output",
    debug::Bool = false,
    # model hyper params
    channels::Vector{Int} = [32, 64, 96, 128],
    block_depth::Int = 2,
    min_freq::Float32 = 1.0f0,
    max_freq::Float32 = 1000.0f0,
    embedding_dims::Int = 32,
    min_signal_rate::Float32 = 0.02f0,
    max_signal_rate::Float32 = 0.95f0,
)
    rng = Random.MersenneTwister()
    Random.seed!(rng, 12345)

    image_dir = joinpath(output_dir, "generated_images")
    ckpt_dir = joinpath(output_dir, "ckpt")
    mkpath(image_dir)
    mkpath(ckpt_dir)

    println("Preparing dataset.")
    ds = OxfordFlowersDataset(
        "oxford_flowers_102/",
        x -> preprocess_image(x, (image_size, image_size)),
        true,
    )
    data_loader = DataLoader(
        ds;
        batchsize = batchsize,
        partial = false,
        collate = true,
        parallel = true,
        rng = rng,
        shuffle = true,
    )

    println("Preparing DDIM.")
    ddim = DenoisingDiffusionImplicitModel(
        (image_size, image_size),
        channels = channels,
        block_depth = block_depth,
        min_freq = min_freq,
        max_freq = max_freq,
        embedding_dims = embedding_dims,
        min_signal_rate = min_signal_rate,
        max_signal_rate = max_signal_rate,
    )
    ps, st = Lux.setup(rng, ddim)

    println("Set optimizer.")
    opt = Optimisers.AdamW(learning_rate, (9.0f-1, 9.99f-1), weight_decay)
    opt_st = Optimisers.setup(opt, ps)

    if CUDA.functional()
        println("GPU is available.")
    else
        println("GPU is not available.")
    end

    ddim = ddim |> gpu
    ps = ps |> gpu
    st = st |> gpu
    opt_st = opt_st |> gpu

    rng_gen = Random.MersenneTwister()
    Random.seed!(rng_gen, 0)

    println("Training.")
    for epoch = 1:epochs
        losses = []
        iter = ProgressBar(data_loader)
        st = Lux.trainmode(st)
        for images in iter
            images = images |> gpu
            loss, ps, st, opt_st = train_step(ddim, images, rng, ps, st, opt_st)
            push!(losses, loss)
            set_description(iter, "Epoch: $(epoch) Loss: $(Statistics.mean(losses))")
            if debug
                break
            end
        end

        st = Lux.testmode(st)
        generated_images, _ = generate(
            ddim,
            Lux.replicate(rng_gen),
            (image_size, image_size, 3, 10),
            val_diffusion_steps,
            ps,
            st,
        )
        generated_images = generated_images |> cpu
        save_as_png(generated_images, image_dir, epoch)
        if epoch % 5 == 0
            save_checkpoint(ps, st, opt_st, ckpt_dir, epoch)
        end
    end
end