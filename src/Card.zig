const std = @import("std");
const mach = @import("mach");
const gpu = mach.gpu;
const gfx = mach.gfx;

const math = mach.math;
const vec2 = math.vec2;
const vec3 = math.vec3;
const vec4 = math.vec4;
const mat4x4 = math.mat4x4;
const Vec2 = math.Vec2;
const Vec3 = math.Vec3;
const Mat3x3 = math.Mat3x3;
const Mat4x4 = math.Mat4x4;

const Card = @This();

pub const mach_module = .card;

pub const mach_systems = .{.tick};

// TODO(card): currently not handling deinit properly

const Uniforms = extern struct {
    /// The view * orthographic projection matrix
    view_projection: math.Mat4x4 align(16),

    /// Total size of the card texture in pixels
    texture_size: math.Vec2 align(16),

    time: f32 align(16),
};

const BuiltPipeline = struct {
    render: *gpu.RenderPipeline,
    texture_sampler: *gpu.Sampler,
    texture_view: *gpu.TextureView,
    bind_group: *gpu.BindGroup,
    uniforms: *gpu.Buffer,

    // Storage buffers
    transforms: *gpu.Buffer,
    uv_transforms: *gpu.Buffer,
    sizes: *gpu.Buffer,

    fn deinit(p: *const BuiltPipeline) void {
        p.render.release();
        p.texture_sampler.release();
        p.texture_view.release();
        p.bind_group.release();
        p.uniforms.release();
        p.transforms.release();
        p.uv_transforms.release();
        p.sizes.release();
    }
};

const buffer_cap = 1024 * 512; // TODO(card): allow user to specify preallocation

var cp_transforms: [buffer_cap]math.Mat4x4 = undefined;
// TODO(d3d12): uv_transform should be a Mat3x3 but our D3D12/HLSL backend cannot handle it.
var cp_uv_transforms: [buffer_cap]math.Mat4x4 = undefined;
var cp_sizes: [buffer_cap]math.Vec2 = undefined;

objects: mach.Objects(.{ .track_fields = true }, struct {
    /// The card model transformation matrix. A card is measured in pixel units, starting from
    /// (0, 0) at the top-left corner and extending to the size of the card. By default, the world
    /// origin (0, 0) lives at the center of the window.
    ///
    /// Example: in a 500px by 500px window, a card located at (0, 0) with size (250, 250) will
    /// cover the top-right hand corner of the window.
    transform: Mat4x4,

    /// UV coordinate transformation matrix describing top-left corner / origin of card, in pixels.
    uv_transform: Mat3x3,

    /// The size of the card, in pixels.
    size: Vec2,
}),

/// A card pipeline renders all cards that are parented to it.
pipelines: mach.Objects(.{ .track_fields = true }, struct {
    /// Which window (device/queue) to use. If not set, this pipeline will not be rendered.
    window: ?mach.ObjectID = null,

    /// Which render pass should be used during rendering. If not set, this pipeline will not be
    /// rendered.
    render_pass: ?*gpu.RenderPassEncoder = null,

    /// Time value to pass to shader program.
    time: f32 = 0,

    /// Texture to use when rendering.
    /// Must be specified for a pipeline entity to be valid.
    texture_view: *gpu.TextureView,
    texture_view_size: math.Vec2,

    /// View*Projection matrix to use when rendering with this pipeline. This controls both
    /// the size of the 'virtual canvas' which is rendered onto, as well as the 'camera position'.
    ///
    /// By default, the size is configured to be equal to the window size in virtual pixels (e.g.
    /// if the window size is 1920x1080, the virtual canvas will also be that size even if ran on a
    /// HiDPI / Retina display where the actual framebuffer is larger than that.) The origin (0, 0)
    /// is configured to be the center of the window:
    ///
    /// ```
    /// const width_px: f32 = @floatFromInt(window.width);
    /// const height_px: f32 = @floatFromInt(window.height);
    /// const projection = math.Mat4x4.projection2D(.{
    ///     .left = -width_px / 2.0,
    ///     .right = width_px / 2.0,
    ///     .bottom = -height_px / 2.0,
    ///     .top = height_px / 2.0,
    ///     .near = -0.1,
    ///     .far = 100000,
    /// });
    /// const view_projection = projection.mul(&Mat4x4.translate(vec3(0, 0, 0)));
    /// ```
    view_projection: ?Mat4x4 = null,

    /// Shader program to use when rendering
    ///
    /// If null, defaults to card.wgsl
    shader: ?*gpu.ShaderModule = null,

    /// Whether to use linear (blurry) or nearest (pixelated) upscaling/downscaling.
    ///
    /// If null, defaults to nearest (pixelated)
    texture_sampler: ?*gpu.Sampler = null,

    /// Alpha and color blending options
    ///
    /// If null, defaults to
    /// .{
    ///   .color = .{ .operation = .add, .src_factor = .src_alpha .dst_factor = .one_minus_src_alpha },
    ///   .alpha = .{ .operation = .add, .src_factor = .one, .dst_factor = .zero },
    /// }
    blend_state: ?gpu.BlendState = null,

    /// Override to enable passing additional data to your shader program.
    bind_group_layout: ?*gpu.BindGroupLayout = null,

    /// Override to enable passing additional data to your shader program.
    bind_group: ?*gpu.BindGroup = null,

    /// Override to enable custom color target state for render pipeline.
    color_target_state: ?gpu.ColorTargetState = null,

    /// Override to enable custom fragment state for render pipeline.
    fragment_state: ?gpu.FragmentState = null,

    /// Override to enable custom pipeline layout.
    layout: ?*gpu.PipelineLayout = null,

    /// Number of cards this pipeline will render.
    /// Read-only, updated as part of Card.tick
    num_cards: u32 = 0,

    /// Internal pipeline state.
    built: ?BuiltPipeline = null,
}),

pub fn tick(card: *Card, core: *mach.Core) !void {
    var pipelines = card.pipelines.slice();
    while (pipelines.next()) |pipeline_id| {
        // Is this pipeline usable for rendering? If not, no need to process it.
        var pipeline = card.pipelines.getValue(pipeline_id);
        if (pipeline.window == null or pipeline.render_pass == null) continue;

        // Changing these fields shouldn't trigger a pipeline rebuild, so clear their update values:
        _ = card.pipelines.updated(pipeline_id, .window);
        _ = card.pipelines.updated(pipeline_id, .render_pass);
        _ = card.pipelines.updated(pipeline_id, .view_projection);

        // If any other fields of the pipeline have been updated, a pipeline rebuild is required.
        if (card.pipelines.anyUpdated(pipeline_id)) {
            rebuildPipeline(core, card, pipeline_id);
        }

        // Find cards parented to this pipeline.
        var pipeline_children = try card.pipelines.getChildren(pipeline_id);
        defer pipeline_children.deinit();

        // If any cards were updated, we update the pipeline's storage buffers to have the new
        // information for all its cards.
        const any_cards_updated = blk: {
            for (pipeline_children.items) |card_id| {
                if (!card.objects.is(card_id)) continue;
                if (card.objects.anyUpdated(card_id)) break :blk true;
            }
            break :blk false;
        };
        if (any_cards_updated) updatePipelineBuffers(card, core, pipeline_id, pipeline_children.items);

        // Do we actually have any cards to render?
        pipeline = card.pipelines.getValue(pipeline_id);
        if (pipeline.num_cards == 0) continue;

        // TODO(card): need a way to specify order of rendering with multiple pipelines
        renderPipeline(card, core, pipeline_id);
    }
}

fn rebuildPipeline(
    core: *mach.Core,
    card: *Card,
    pipeline_id: mach.ObjectID,
) void {
    // Destroy the current pipeline, if built.
    var pipeline = card.pipelines.getValue(pipeline_id);
    defer card.pipelines.setValueRaw(pipeline_id, pipeline);
    if (pipeline.built) |built| built.deinit();

    // Reference any user-provided objects.
    pipeline.texture_view.reference();
    if (pipeline.shader) |v| v.reference();
    if (pipeline.texture_sampler) |v| v.reference();
    if (pipeline.bind_group_layout) |v| v.reference();
    if (pipeline.bind_group) |v| v.reference();
    if (pipeline.layout) |v| v.reference();

    const window = core.windows.getValue(pipeline.window.?);
    const device = window.device;

    const label = @tagName(mach_module) ++ ".rebuildPipeline";

    // Storage buffers
    const transforms = device.createBuffer(&.{
        .label = label ++ " transforms",
        .usage = .{ .storage = true, .copy_dst = true },
        .size = @sizeOf(math.Mat4x4) * buffer_cap,
        .mapped_at_creation = .false,
    });
    const uv_transforms = device.createBuffer(&.{
        .label = label ++ " uv_transforms",
        .usage = .{ .storage = true, .copy_dst = true },
        // TODO(d3d12): uv_transform should be a Mat3x3 but our D3D12/HLSL backend cannot handle it.
        .size = @sizeOf(math.Mat4x4) * buffer_cap,
        .mapped_at_creation = .false,
    });
    const sizes = device.createBuffer(&.{
        .label = label ++ " sizes",
        .usage = .{ .storage = true, .copy_dst = true },
        .size = @sizeOf(math.Vec2) * buffer_cap,
        .mapped_at_creation = .false,
    });

    const texture_sampler = pipeline.texture_sampler orelse device.createSampler(&.{
        .label = label ++ " sampler",
        .mag_filter = .nearest,
        .min_filter = .nearest,
    });
    const uniforms = device.createBuffer(&.{
        .label = label ++ " uniforms",
        .usage = .{ .copy_dst = true, .uniform = true },
        .size = @sizeOf(Uniforms),
        .mapped_at_creation = .false,
    });
    const bind_group_layout = pipeline.bind_group_layout orelse device.createBindGroupLayout(
        &gpu.BindGroupLayout.Descriptor.init(.{
            .label = label,
            .entries = &.{
                gpu.BindGroupLayout.Entry.initBuffer(0, .{ .vertex = true, .fragment = true }, .uniform, false, 0),
                gpu.BindGroupLayout.Entry.initBuffer(1, .{ .vertex = true }, .read_only_storage, false, 0),
                gpu.BindGroupLayout.Entry.initBuffer(2, .{ .vertex = true }, .read_only_storage, false, 0),
                gpu.BindGroupLayout.Entry.initBuffer(3, .{ .vertex = true }, .read_only_storage, false, 0),
                gpu.BindGroupLayout.Entry.initSampler(4, .{ .fragment = true }, .filtering),
                gpu.BindGroupLayout.Entry.initTexture(5, .{ .fragment = true }, .float, .dimension_2d, false),
            },
        }),
    );
    defer bind_group_layout.release();

    const bind_group = pipeline.bind_group orelse device.createBindGroup(
        &gpu.BindGroup.Descriptor.init(.{
            .label = label,
            .layout = bind_group_layout,
            .entries = &.{
                gpu.BindGroup.Entry.initBuffer(0, uniforms, 0, @sizeOf(Uniforms), @sizeOf(Uniforms)),
                gpu.BindGroup.Entry.initBuffer(1, transforms, 0, @sizeOf(math.Mat4x4) * buffer_cap, @sizeOf(math.Mat4x4)),
                gpu.BindGroup.Entry.initBuffer(2, uv_transforms, 0, @sizeOf(math.Mat3x3) * buffer_cap, @sizeOf(math.Mat3x3)),
                gpu.BindGroup.Entry.initBuffer(3, sizes, 0, @sizeOf(math.Vec2) * buffer_cap, @sizeOf(math.Vec2)),
                gpu.BindGroup.Entry.initSampler(4, texture_sampler),
                gpu.BindGroup.Entry.initTextureView(5, pipeline.texture_view),
            },
        }),
    );
    pipeline.texture_view.release();

    const blend_state = pipeline.blend_state orelse gpu.BlendState{
        .color = .{
            .operation = .add,
            .src_factor = .src_alpha,
            .dst_factor = .one_minus_src_alpha,
        },
        .alpha = .{
            .operation = .add,
            .src_factor = .one,
            .dst_factor = .zero,
        },
    };

    const shader_module = pipeline.shader orelse device.createShaderModuleWGSL("card.wgsl", @embedFile("card.wgsl"));
    defer shader_module.release();

    const color_target = pipeline.color_target_state orelse gpu.ColorTargetState{
        .format = window.framebuffer_format,
        .blend = &blend_state,
        .write_mask = gpu.ColorWriteMaskFlags.all,
    };
    const fragment = pipeline.fragment_state orelse gpu.FragmentState.init(.{
        .module = shader_module,
        .entry_point = "fragMain",
        .targets = &.{color_target},
    });

    const bind_group_layouts = [_]*gpu.BindGroupLayout{bind_group_layout};
    const pipeline_layout = pipeline.layout orelse device.createPipelineLayout(&gpu.PipelineLayout.Descriptor.init(.{
        .label = label,
        .bind_group_layouts = &bind_group_layouts,
    }));
    defer pipeline_layout.release();
    const render_pipeline = device.createRenderPipeline(&gpu.RenderPipeline.Descriptor{
        .label = label,
        .fragment = &fragment,
        .layout = pipeline_layout,
        .vertex = gpu.VertexState{
            .module = shader_module,
            .entry_point = "vertMain",
        },
    });

    pipeline.built = BuiltPipeline{
        .render = render_pipeline,
        .texture_sampler = texture_sampler,
        .texture_view = pipeline.texture_view,
        .bind_group = bind_group,
        .uniforms = uniforms,
        .transforms = transforms,
        .uv_transforms = uv_transforms,
        .sizes = sizes,
    };
    pipeline.num_cards = 0;
}

fn updatePipelineBuffers(
    card: *Card,
    core: *mach.Core,
    pipeline_id: mach.ObjectID,
    pipeline_children: []const mach.ObjectID,
) void {
    const pipeline = card.pipelines.getValue(pipeline_id);
    const window = core.windows.getValue(pipeline.window.?);
    const device = window.device;

    const label = @tagName(mach_module) ++ ".updatePipelineBuffers";
    const encoder = device.createCommandEncoder(&.{ .label = label });
    defer encoder.release();

    var i: u32 = 0;
    for (pipeline_children) |card_id| {
        if (!card.objects.is(card_id)) continue;
        const s = card.objects.getValue(card_id);

        cp_transforms[i] = s.transform;

        // TODO(d3d12): uv_transform should be a Mat3x3 but our D3D12/HLSL backend cannot handle it.
        const uv = s.uv_transform;
        cp_uv_transforms[i].v[0] = vec4(uv.v[0].x(), uv.v[0].y(), uv.v[0].z(), 0.0);
        cp_uv_transforms[i].v[1] = vec4(uv.v[1].x(), uv.v[1].y(), uv.v[1].z(), 0.0);
        cp_uv_transforms[i].v[2] = vec4(uv.v[2].x(), uv.v[2].y(), uv.v[2].z(), 0.0);
        cp_uv_transforms[i].v[3] = vec4(0.0, 0.0, 0.0, 0.0);
        cp_sizes[i] = s.size;
        i += 1;
    }

    // Sort cards back-to-front for draw order, alpha blending
    const Context = struct {
        // TODO(d3d12): uv_transform should be a Mat3x3 but our D3D12/HLSL backend cannot handle it.
        transforms: []Mat4x4,
        uv_transforms: []Mat4x4,
        sizes: []Vec2,

        pub fn lessThan(ctx: @This(), a: usize, b: usize) bool {
            const a_z = ctx.transforms[a].translation().z();
            const b_z = ctx.transforms[b].translation().z();
            // Greater z values are further away, and thus should render/sort before those with lesser z values.
            return a_z > b_z;
        }

        pub fn swap(ctx: @This(), a: usize, b: usize) void {
            std.mem.swap(Mat4x4, &ctx.transforms[a], &ctx.transforms[b]);
            // TODO(d3d12): uv_transform should be a Mat3x3 but our D3D12/HLSL backend cannot handle it.
            std.mem.swap(Mat4x4, &ctx.uv_transforms[a], &ctx.uv_transforms[b]);
            std.mem.swap(Vec2, &ctx.sizes[a], &ctx.sizes[b]);
        }
    };
    std.sort.pdqContext(0, i, Context{
        .transforms = cp_transforms[0..i],
        .uv_transforms = cp_uv_transforms[0..i],
        .sizes = cp_sizes[0..i],
    });

    card.pipelines.set(pipeline_id, .num_cards, i);
    if (i > 0) {
        encoder.writeBuffer(pipeline.built.?.transforms, 0, cp_transforms[0..i]);
        encoder.writeBuffer(pipeline.built.?.uv_transforms, 0, cp_uv_transforms[0..i]);
        encoder.writeBuffer(pipeline.built.?.sizes, 0, cp_sizes[0..i]);

        var command = encoder.finish(&.{ .label = label });
        defer command.release();
        window.queue.submit(&[_]*gpu.CommandBuffer{command});
    }
}

fn renderPipeline(
    card: *Card,
    core: *mach.Core,
    pipeline_id: mach.ObjectID,
) void {
    const pipeline = card.pipelines.getValue(pipeline_id);
    const window = core.windows.getValue(pipeline.window.?);
    const device = window.device;

    const label = @tagName(mach_module) ++ ".renderPipeline";
    const encoder = device.createCommandEncoder(&.{ .label = label });
    defer encoder.release();

    // Update uniform buffer
    const view_projection = pipeline.view_projection orelse blk: {
        const width_px: f32 = @floatFromInt(window.width);
        const height_px: f32 = @floatFromInt(window.height);
        break :blk math.Mat4x4.projection2D(.{
            .left = -width_px / 2,
            .right = width_px / 2,
            .bottom = -height_px / 2,
            .top = height_px / 2,
            .near = -0.1,
            .far = 100000,
        });
    };
    const uniforms = Uniforms{
        .view_projection = view_projection,
        // TODO(card): dimensions of multi-textures, number of multi-textures present
        .texture_size = pipeline.texture_view_size,
        .time = pipeline.time,
    };
    encoder.writeBuffer(pipeline.built.?.uniforms, 0, &[_]Uniforms{uniforms});
    var command = encoder.finish(&.{ .label = label });
    defer command.release();
    window.queue.submit(&[_]*gpu.CommandBuffer{command});

    // Draw the card batch
    const total_vertices = pipeline.num_cards * 6;
    pipeline.render_pass.?.setPipeline(pipeline.built.?.render);
    // TODO(card): can we remove unused dynamic offsets?
    pipeline.render_pass.?.setBindGroup(0, pipeline.built.?.bind_group, &.{});
    pipeline.render_pass.?.draw(total_vertices, 1, 0, 0);
}
