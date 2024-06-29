//-----------------------------------------------------------------------------
// Vertex shader
//-----------------------------------------------------------------------------
struct VertexOutput {
  // Vertex position
  @builtin(position) Position : vec4<f32>,

  // UV coordinate
  @location(0) fragUV : vec2<f32>,
};

// Our vertex shader will recieve these parameters
struct Uniforms {
  // The view * orthographic projection matrix
  view_projection: mat4x4<f32>,

  // Total size of the sprite texture in pixels
  texture_size: vec2<f32>,

  time: f32,
};

@group(0) @binding(0) var<uniform> uniforms : Uniforms;

// Sprite model transformation matrices
@group(0) @binding(1) var<storage, read> sprite_transforms: array<mat4x4<f32>>;

// Sprite UV coordinate transformation matrices. Sprite UV coordinates are (0, 0) at the top-left
// corner, and in pixels.
@group(0) @binding(2) var<storage, read> sprite_uv_transforms: array<mat3x3<f32>>;

// Sprite sizes, in pixels.
@group(0) @binding(3) var<storage, read> sprite_sizes: array<vec2<f32>>;

@vertex
fn vertMain(
  @builtin(vertex_index) VertexIndex : u32
) -> VertexOutput {
  // Our vertex shader will be called six times per sprite (2 triangles make up a sprite, so six
  // vertices.) The VertexIndex tells us which vertex we need to render, so we know e.g. vertices
  // 0-5 correspond to the first sprite, vertices 6-11 correspond to the second sprite, and so on.
  let sprite_transform = sprite_transforms[VertexIndex / 6];
  let sprite_uv_transform = sprite_uv_transforms[VertexIndex / 6];
  let sprite_size = sprite_sizes[VertexIndex / 6];

  // Imagine the vertices and UV coordinates of a card. There are two triangles, the UV coordinates
  // describe the corresponding location of each vertex on the texture. We hard-code the vertex
  // positions and UV coordinates here:
  let positions = array<vec2<f32>, 6>(
      vec2<f32>(0, 0), // left, bottom
      vec2<f32>(0, 1), // left, top
      vec2<f32>(1, 0), // right, bottom
      vec2<f32>(1, 0), // right, bottom
      vec2<f32>(0, 1), // left, top
      vec2<f32>(1, 1), // right, top
  );
  let uvs = array<vec2<f32>, 6>(
      vec2<f32>(0, 1), // left, bottom
      vec2<f32>(0, 0), // left, top
      vec2<f32>(1, 1), // right, bottom
      vec2<f32>(1, 1), // right, bottom
      vec2<f32>(0, 0), // left, top
      vec2<f32>(1, 0), // right, top
  );

  // Based on the vertex index, we determine which positions[n] and uvs[n] we need to use. Our
  // vertex shader is invoked 6 times per sprite, we need to produce the right vertex/uv coordinates
  // each time to produce a textured card.
  let pos_2d = positions[VertexIndex % 6];
  var uv = uvs[VertexIndex % 6];

  // Currently, our pos_2d and uv coordinates describe a card that covers 1px by 1px; and the UV
  // coordinates describe using the entire texture. We alter the coordinates to describe the
  // desired sprite location, size, and apply a subset of the texture instead of the entire texture.
  var pos = vec4<f32>(pos_2d * sprite_size, 0, 1); // normalized -> pixels
  pos = sprite_transform * pos; // apply sprite transform (pixels)
  pos = uniforms.view_projection * pos; // pixels -> normalized

  uv *= sprite_size; // normalized -> pixels
  uv = (sprite_uv_transform * vec3<f32>(uv, 1)).xy; // apply sprite UV transform (pixels)
  uv /= uniforms.texture_size; // pixels -> normalized

  var output : VertexOutput;
  output.Position = pos;
  output.fragUV = uv;
  return output;
}

//-----------------------------------------------------------------------------
// Fragment shader
//-----------------------------------------------------------------------------
@group(0) @binding(4) var spriteSampler: sampler;
@group(0) @binding(5) var spriteTexture: texture_2d<f32>;

@fragment
fn fragMain(
  @location(0) uv: vec2<f32>
) -> @location(0) vec4<f32> {
    // // start screen 'dragon claws' effect
    // let time = uniforms.time + 50; // add 50s so that we're already into the animation starting
    // let uv_x = uv.x;
    // let uv_y = (1.0-uv.y);
	// let c: f32 = 1. - fract((uv_y * 1.5 + time * 0.2) * hash11(floor(1. / uv_y * 10. + uv_x * 150.)) * 1.5 + 0.4);
	// let sky: vec3<f32> = vec3<f32>(0.5, 0.7, 0.8) * ((uv_x * 0.75) - 0.5);
	// return vec4<f32>(mix(vec3<f32>(0., 0., 0.), sky, c), 1.);

    // // rain
    // let time = uniforms.time + 50; // add 50s so that we're already into the animation starting
    // let rain_speed: f32 = 2.125;
	// let rain_streak: f32 = 6.0;
    // let rain_scale: f32 = 3.0;
    // let uv_x = uv.x * rain_scale;
    // let uv_y = (1.0-uv.y) * rain_scale;
	// let c: f32 = 1. - fract((uv_y * 0.5 + time * rain_speed + 0.1) * hash11(floor(uv_y * 50. + uv_x * 150.)) * 0.5) * rain_streak;
	// let droplet: vec3<f32> = vec3<f32>(0.5, 0.7, 0.8) * 1.5;
    // if (c * 0.2 <= 0.0) {
    //     discard;
    // }
	// return vec4<f32>(mix(vec3<f32>(0., 0., 0.), droplet, c * 0.2), c * 0.4);

    // Clouds and fog
    let time: f32 = uniforms.time + 50; // add 50s so that we're already into the animation starting
    // Fog
	let fog_speed: vec2<f32> = vec2<f32>(0.2, 0.);
	let fog_color: vec3<f32> = vec3<f32>(1., 1., 1.);
    let fog_intensity: f32 = modulo2(time / 5.0, 1.0);
    let fog_amount: f32 = fog_intensity;
	let fog_noise: f32 = 0.5;
	let fog_noise_speed: f32 = 0.02;

    // Clouds
	let cloud_speed: vec2<f32> = vec2<f32>(0.4, 0.);
	let cloud_color: vec3<f32> = vec3<f32>(1., 1., 1.);
    let cloud_intensity: f32 = modulo2(time / 5.0, 1.0);
    let cloud_amount: f32 = cloud_intensity;
	let cloud_noise: f32 = fog_noise*2.;
	let cloud_noise_speed: f32 = fog_noise_speed*6.;

    let cloud_alpha = cloudFog(uv, time, 1.0, cloud_speed, cloud_noise, cloud_noise_speed, cloud_amount, cloud_intensity);
    let fog_alpha = cloudFog(uv, time, 0.0, fog_speed, fog_noise, fog_noise_speed, fog_amount, fog_intensity);
    let color = alphaOver(vec4<f32>(fog_color, fog_alpha), vec4<f32>(cloud_color, cloud_alpha));
    if (color.a <= 0.0) { discard; }
    return color;

    // // Background image
    // var c = textureSample(spriteTexture, spriteSampler, fragUV);
    // if (c.a <= 0.0) {
    //     discard;
    // }
    // return c;
}

// Straight (not premultiplied) alpha-over operation, drawing src over dst.
fn alphaOver(a: vec4<f32>, b: vec4<f32>) -> vec4<f32> {
    const alpha: f32 = a.a + b.a * (1 - a.a);
    const color: vec3<f32> = ((a.rgb * a.a) + (b.rgb * b.a * (1 - a.a))) / vec3<f32>(alpha);
    return vec4<f32>(color, alpha);
}

// Cloud / fog alpha calculation
fn cloudFog(uv: vec2<f32>, time: f32, is_clouds: f32, speed: vec2<f32>, noise: f32, noise_speed: f32, cloud_amount: f32, cloud_intensity: f32) -> f32 {
    let invert = ((1.-is_clouds) - 0.5) * 2.0; // -1 if clouds, 1 otherwise
	let height_additive: f32 = 1.-(cloud_amount * 1.2 * (1.0+is_clouds));
	let density: f32 = 0.4;
	let density_speed: f32 = 0.025;
	let edge_sharpness_factor: f32 = 3.;
	let intensity_factor: f32 = 1.;
    let max_intensity = 0.75 + cloud_intensity;
	let height_factor: f32 = 1.0;
	let height_speed: f32 = -speed.x;
    let uvv = vec2(uv.x, 1.-uv.y*invert) * 4.0;
	let uvt: vec2<f32> = uvv + vec2<f32>(speed * time);
	var v_noise: f32 = 0.5 + simplex3d_fractal(vec3<f32>(uvt, time * noise_speed) * noise * 1.);
	v_noise = 1. - pow(1. - v_noise, intensity_factor);
    let uvh = vec2(uv.x, 1.-uv.y) * 2.0 * invert;
	let height_mask: f32 = clamp((loopNoise(uvt.x*0.9, 12.) * 1. - uvh.y * height_factor) - (height_additive), 0., 1.);
	let height2_mask: f32 = clamp((loopNoise(uvt.x*0.8, 24.) * 1. - uvh.y * height_factor) - (height_additive), 0., 1.);
    let mask: f32 = min(clamp(height2_mask - (1.-height_mask), 0., 1.), max_intensity);
    return clamp(v_noise - (1.-mask), 0., 1.);
}

fn hash11(p: f32) -> f32 {
	var p2: vec2<f32> = fract(vec2<f32>(p * 5.3983, p * 5.4427));
	p2 = p2 + (dot(p2.yx, p2.xy + vec2<f32>(21.5351, 14.3137)));
	return fract(p2.x * p2.y * 95.4337) * 0.5 + 0.5;
} 

//------------------------------------------------------------------------
// simplex3d algorithm
// ported from https://www.shadertoy.com/view/XsX3zB
// The MIT License, Copyright © 2013 Nikita Miropolskiy
//------------------------------------------------------------------------
fn random3(c: vec3<f32>) -> vec3<f32> {
	var j: f32 = 4096. * sin(dot(c, vec3<f32>(17., 59.4, 15.)));
	var r: vec3<f32>;
	r.z = fract(512. * j);
	j = j * (0.125);
	r.x = fract(512. * j);
	j = j * (0.125);
	r.y = fract(512. * j);
	return r - 0.5;
} 
fn simplex3d(p: vec3<f32>) -> f32 {
    let F3: f32 = 0.3333333;
    let G3: f32 = 0.1666667;
    let s: vec3<f32> = floor(p + dot(p, vec3<f32>(F3)));
	var x: vec3<f32> = p - s + dot(s, vec3<f32>(G3));
	let e: vec3<f32> = step(vec3<f32>(0.), x - x.yzx);
	let i1: vec3<f32> = e * (1. - e.zxy);
	let i2: vec3<f32> = 1. - e.zxy * (1. - e);
	let x1: vec3<f32> = x - i1 + G3;
	let x2: vec3<f32> = x - i2 + 2. * G3;
	let x3: vec3<f32> = x - 1. + 3. * G3;
	var w: vec4<f32>;
	var d: vec4<f32>;
	w.x = dot(x, x);
	w.y = dot(x1, x1);
	w.z = dot(x2, x2);
	w.w = dot(x3, x3);
	w = max(0.6 - w, vec4<f32>(0.));
	d.x = dot(random3(s), x);
	d.y = dot(random3(s + i1), x1);
	d.z = dot(random3(s + i2), x2);
	d.w = dot(random3(s + 1.), x3);
	w = w * (w);
	w = w * (w);
	d = d * (w);
	return dot(d, vec4<f32>(52.));
} 
fn simplex3d_fractal(m: vec3<f32>) -> f32 {
    // rot1 mat3x3 rows
    let rot1_1 = vec3<f32>(-0.37, 0.36, 0.85);
    let rot1_2 = vec3<f32>(-0.14, -0.93, 0.34);
    let rot1_3 = vec3<f32>(0.92, 0.01, 0.4);

    // rot2 mat3x3 rows
    let rot2_1 = vec3<f32>(-0.55, -0.39, 0.74);
    let rot2_2 = vec3<f32>(0.33, -0.91, -0.24);
    let rot2_3 = vec3<f32>(0.77, 0.12, 0.63);

    // rot3 mat3x3 rows
    let rot3_1 = vec3<f32>(-0.71, 0.52, -0.47);
    let rot3_2 = vec3<f32>(-0.08, -0.72, -0.68);
    let rot3_3 = vec3<f32>(-0.7, -0.45, 0.56);

    let m_rot1 = mat3x3TimesVector(rot1_1, rot1_2, rot1_3, m);
    let m_rot2 = mat3x3TimesVector(rot2_1, rot2_2, rot2_3, m);
    let m_rot3 = mat3x3TimesVector(rot3_1, rot3_2, rot3_3, m);

    return 0.5333333 * simplex3d(m_rot2) + 0.2666667 * simplex3d(2. * m_rot2) + 0.1333333 * simplex3d(4. * m_rot3) + 0.0666667 * simplex3d(8. * m);
} 
fn hash(n: f32) -> f32 {
	return fract(sin(n) * 10000.);
} 
fn loopNoise(x: f32, loopLen: f32) -> f32 {
    let xv: f32 = modulo(x, loopLen);
	let i: f32 = floor(xv);
	let f: f32 = fract(xv);
	let u: f32 = f * f * f * (f * (f * 6. - 15.) + 10.);
	return mix(hash(i), hash(modulo(i + 1., loopLen)), u);
}
fn modulo(x: f32, y: f32) -> f32 {
    return x - y * floor(x/y);
}
fn modulo2(x: f32, y: f32) -> f32 {
    return x - y * floor(x/y);
}
fn mat3x3TimesVector(r1: vec3<f32>, r2: vec3<f32>, r3: vec3<f32>, v: vec3<f32>) -> vec3<f32> {
    var result = vec3<f32>(0,0,0);    
    for (var row = 0; row < 3; row++) {
        for (var col = 0; col < 3; col++) {
            if (row == 0) {
                result[col] += r1[col] * v[row];
            } else if (row == 1) {
                result[col] += r2[col] * v[row];
            } else if (row == 2) {
                result[col] += r3[col] * v[row];
            }
        }
    }
    return result;
}
//------------------------------------------------------------------------
// end simplex3d algorithm
//------------------------------------------------------------------------
