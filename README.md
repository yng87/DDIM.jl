# DDIM.jl

[Lux.jl](https://github.com/avik-pal/Lux.jl) implementation of Denoising Diffusion Implicit Models ([arXiv:2010.02502](https://arxiv.org/abs/2010.02502)).

The implementation follows [the Keras example](https://keras.io/examples/generative/ddim/).

![](output-96/generated_images_step/img_1.gif)
![](output-96/generated_images_step/img_2.gif)
# Example

## Dataset
Download `Dataset images` from [102 Category Flower Dataset](https://www.robots.ox.ac.uk/~vgg/data/flowers/102/).


## Training
```bash
$julia --project train.jl \
    --epochs 25 \
    --image-size 96 \
    --val-diffusion-steps 80 \
    --dataset_dir oxford_flowers_102
    --output-dir ./output-96
```

## Image generation

```bash
$julia --project generate.jl \
    ./output-96/ckpt/checkpoint_25.bson \
    --image-size 96 \
    --diffusion-steps 80 \
    --output-dir ./output-96/generated_images_step
```


