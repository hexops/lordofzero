const std = @import("std");
const mach = @import("mach");

const gpu = mach.gpu;
const gfx = mach.gfx;
const math = mach.math;

pub const name = .card;
pub const Mod = mach.Mod(@This());

pub const components = .{
    // Card options here
    .transform = .{ .type = math.Mat4x4 },
    .uv_transform = .{ .type = math.Mat3x3 },
    .size = .{ .type = math.Vec2 },

    // Pipeline options below here
    .texture_view = .{ .type = *gpu.TextureView },
    .texture_view_size = .{ .type = math.Vec2 },
    // .texture_view2 = .{ .type = *gpu.TextureView },
    // .texture_view3 = .{ .type = *gpu.TextureView },
    // .texture_view4 = .{ .type = *gpu.TextureView },

    .view_projection = .{ .type = math.Mat4x4 },
    .shader = .{ .type = *gpu.ShaderModule },
    .texture_sampler = .{ .type = *gpu.Sampler },
    .blend_state = .{ .type = gpu.BlendState },
    .render_pass_id = .{ .type = u32 },

    .built = .{ .type = BuiltPipeline, .description = "internal" },
};

pub const systems = .{
    .init = .{ .handler = init },
    .deinit = .{ .handler = deinit },
    .update = .{ .handler = update },
    .update_pipelines = .{ .handler = updatePipelines },
    .pre_render = .{ .handler = preRender },
    .render = .{ .handler = render },
};

const Uniforms = extern struct {
    // WebGPU requires that the size of struct fields are multiples of 16
    // So we use align(16) and 'extern' to maintain field order

    /// The view * orthographic projection matrix
    view_projection: math.Mat4x4 align(4 * 4),

    /// Total size of the card texture in pixels
    texture_size: math.Vec2 align(4 * 2),

    time: f32 align(4 * 1),
};

pub const BuiltPipeline = struct {
    render: *gpu.RenderPipeline,
    texture_sampler: *gpu.Sampler,
    texture_view: *gpu.TextureView,
    // texture_view2: ?*gpu.TextureView,
    // texture_view3: ?*gpu.TextureView,
    // texture_view4: ?*gpu.TextureView,
    bind_group: *gpu.BindGroup,
    uniforms: *gpu.Buffer,

    // Storage buffers
    transforms: *gpu.Buffer,
    uv_transforms: *gpu.Buffer,
    sizes: *gpu.Buffer,

    pub fn deinit(p: *const BuiltPipeline) void {
        p.render.release();
        p.texture_sampler.release();
        p.texture_view.release();
        // if (p.texture_view2) |v| v.release();
        // if (p.texture_view3) |v| v.release();
        // if (p.texture_view4) |v| v.release();
        p.bind_group.release();
        p.uniforms.release();
        p.transforms.release();
        p.uv_transforms.release();
        p.sizes.release();
    }
};

/// Which render pass should be used during .render
render_pass_id: u32 = 0,
render_pass: ?*gpu.RenderPassEncoder = null,
time: f32 = 0,

fn init(card: *Mod) void {
    card.init(.{});
}

fn deinit(entities: *mach.Entities.Mod) !void {
    var q = try entities.query(.{
        .built_pipelines = Mod.read(.built),
    });
    while (q.next()) |v| {
        for (v.built_pipelines) |built| {
            built.deinit();
        }
    }
}

fn updatePipelines(entities: *mach.Entities.Mod, core: *mach.Core.Mod, card: *Mod) !void {
    // // Destroy all built render pipelines. We will rebuild them all.
    // try deinit(entities);

    var q = try entities.query(.{
        .ids = mach.Entities.Mod.read(.id),
        .texture_views = Mod.read(.texture_view),
    });
    while (q.next()) |v| {
        for (v.ids, v.texture_views) |card_id, texture_view| {
            try buildPipeline(core, card, card_id, texture_view);
        }
    }
}

fn buildPipeline(
    core: *mach.Core.Mod,
    card: *Mod,
    card_id: mach.EntityID,
    texture_view: *gpu.TextureView,
) !void {
    // TODO: optimize by removing the component get/set calls in this function where possible
    // and instead use .write() queries
    // const opt_texture_view2 = card.get(card_id, .texture_view2);
    // const opt_texture_view3 = card.get(card_id, .texture_view3);
    // const opt_texture_view4 = card.get(card_id, .texture_view4);
    const opt_shader = card.get(card_id, .shader);
    const opt_texture_sampler = card.get(card_id, .texture_sampler);
    const opt_blend_state = card.get(card_id, .blend_state);

    const device = core.state().device;
    const label = @tagName(name) ++ ".buildPipeline";

    // Storage buffers
    const transforms = device.createBuffer(&.{
        .label = label ++ " transforms",
        .usage = .{ .storage = true, .copy_dst = true },
        .size = @sizeOf(math.Mat4x4) * 1,
        .mapped_at_creation = .false,
    });
    const uv_transforms = device.createBuffer(&.{
        .label = label ++ " uv_transforms",
        .usage = .{ .storage = true, .copy_dst = true },
        .size = @sizeOf(math.Mat3x3) * 1,
        .mapped_at_creation = .false,
    });
    const sizes = device.createBuffer(&.{
        .label = label ++ " sizes",
        .usage = .{ .storage = true, .copy_dst = true },
        .size = @sizeOf(math.Vec2) * 1,
        .mapped_at_creation = .false,
    });

    const texture_sampler = opt_texture_sampler orelse device.createSampler(&.{
        .label = label ++ " sampler",
        .mag_filter = .nearest,
        .min_filter = .nearest,

        .address_mode_u = .clamp_to_edge,
        .address_mode_v = .clamp_to_edge,
        .address_mode_w = .clamp_to_edge,
    });
    const uniforms = device.createBuffer(&.{
        .label = label ++ " uniforms",
        .usage = .{ .copy_dst = true, .uniform = true },
        .size = @sizeOf(Uniforms),
        .mapped_at_creation = .false,
    });
    const bind_group_layout = device.createBindGroupLayout(
        &gpu.BindGroupLayout.Descriptor.init(.{
            .label = label,
            .entries = &.{
                gpu.BindGroupLayout.Entry.buffer(0, .{ .vertex = true, .fragment = true }, .uniform, false, 0),
                gpu.BindGroupLayout.Entry.buffer(1, .{ .vertex = true }, .read_only_storage, false, 0),
                gpu.BindGroupLayout.Entry.buffer(2, .{ .vertex = true }, .read_only_storage, false, 0),
                gpu.BindGroupLayout.Entry.buffer(3, .{ .vertex = true }, .read_only_storage, false, 0),
                gpu.BindGroupLayout.Entry.sampler(4, .{ .fragment = true }, .filtering),
                gpu.BindGroupLayout.Entry.texture(5, .{ .fragment = true }, .float, .dimension_2d, false),
                // gpu.BindGroupLayout.Entry.texture(6, .{ .fragment = true }, .float, .dimension_2d, false),
                // gpu.BindGroupLayout.Entry.texture(7, .{ .fragment = true }, .float, .dimension_2d, false),
                // gpu.BindGroupLayout.Entry.texture(8, .{ .fragment = true }, .float, .dimension_2d, false),
            },
        }),
    );
    defer bind_group_layout.release();

    // const texture_view2 = if (opt_texture_view2) |v| v else texture_view;
    // const texture_view3 = if (opt_texture_view3) |v| v else texture_view;
    // const texture_view4 = if (opt_texture_view4) |v| v else texture_view;
    // // TODO: texture views 2-4 leak

    const bind_group = device.createBindGroup(
        &gpu.BindGroup.Descriptor.init(.{
            .label = label,
            .layout = bind_group_layout,
            .entries = &.{
                if (mach.use_sysgpu)
                    gpu.BindGroup.Entry.buffer(0, uniforms, 0, @sizeOf(Uniforms), @sizeOf(Uniforms))
                else
                    gpu.BindGroup.Entry.buffer(0, uniforms, 0, @sizeOf(Uniforms)),
                if (mach.use_sysgpu)
                    gpu.BindGroup.Entry.buffer(1, transforms, 0, @sizeOf(math.Mat4x4) * 1, @sizeOf(math.Mat4x4))
                else
                    gpu.BindGroup.Entry.buffer(1, transforms, 0, @sizeOf(math.Mat4x4) * 1),
                if (mach.use_sysgpu)
                    gpu.BindGroup.Entry.buffer(2, uv_transforms, 0, @sizeOf(math.Mat3x3) * 1, @sizeOf(math.Mat3x3))
                else
                    gpu.BindGroup.Entry.buffer(2, uv_transforms, 0, @sizeOf(math.Mat3x3) * 1),
                if (mach.use_sysgpu)
                    gpu.BindGroup.Entry.buffer(3, sizes, 0, @sizeOf(math.Vec2) * 1, @sizeOf(math.Vec2))
                else
                    gpu.BindGroup.Entry.buffer(3, sizes, 0, @sizeOf(math.Vec2) * 1),
                gpu.BindGroup.Entry.sampler(4, texture_sampler),
                gpu.BindGroup.Entry.textureView(5, texture_view),
                // gpu.BindGroup.Entry.textureView(6, texture_view2),
                // gpu.BindGroup.Entry.textureView(7, texture_view3),
                // gpu.BindGroup.Entry.textureView(8, texture_view4),
            },
        }),
    );

    const blend_state = opt_blend_state orelse gpu.BlendState{
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

    const shader_module = opt_shader orelse device.createShaderModuleWGSL("card.wgsl", @embedFile("card.wgsl"));
    defer shader_module.release();

    const color_target = gpu.ColorTargetState{
        .format = core.get(core.state().main_window, .framebuffer_format).?,
        .blend = &blend_state,
        .write_mask = gpu.ColorWriteMaskFlags.all,
    };
    const fragment = gpu.FragmentState.init(.{
        .module = shader_module,
        .entry_point = "fragMain",
        .targets = &.{color_target},
    });

    const bind_group_layouts = [_]*gpu.BindGroupLayout{bind_group_layout};
    const pipeline_layout = device.createPipelineLayout(&gpu.PipelineLayout.Descriptor.init(.{
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

    const built = BuiltPipeline{
        .render = render_pipeline,
        .texture_sampler = texture_sampler,
        .texture_view = texture_view,
        // .texture_view2 = opt_texture_view2,
        // .texture_view3 = opt_texture_view3,
        // .texture_view4 = opt_texture_view4,
        .bind_group = bind_group,
        .uniforms = uniforms,
        .transforms = transforms,
        .uv_transforms = uv_transforms,
        .sizes = sizes,
    };
    try card.set(card_id, .built, built);
}

fn preRender(entities: *mach.Entities.Mod, core: *mach.Core.Mod, card: *Mod) !void {
    const label = @tagName(name) ++ ".preRender";
    const encoder = core.state().device.createCommandEncoder(&.{ .label = label });
    defer encoder.release();

    var q = try entities.query(.{
        .ids = mach.Entities.Mod.read(.id),
        .built_pipelines = Mod.read(.built),
        .texture_view_sizes = Mod.read(.texture_view_size),
        .render_pass_ids = Mod.read(.render_pass_id),
    });
    while (q.next()) |v| {
        for (v.ids, v.built_pipelines, v.texture_view_sizes, v.render_pass_ids) |id, built, texture_view_size, render_pass_id| {
            if (render_pass_id != card.state().render_pass_id) continue;
            const view_projection = card.get(id, .view_projection) orelse blk: {
                const width_px: f32 = @floatFromInt(mach.core.size().width);
                const height_px: f32 = @floatFromInt(mach.core.size().height);
                break :blk math.Mat4x4.projection2D(.{
                    .left = -width_px / 2,
                    .right = width_px / 2,
                    .bottom = -height_px / 2,
                    .top = height_px / 2,
                    .near = -0.1,
                    .far = 100000,
                });
            };

            // Update uniform buffer
            const uniforms = Uniforms{
                .view_projection = view_projection,
                // TODO(sysgpu): add the ability to get width/height of a texture view
                .texture_size = texture_view_size,
                .time = card.state().time,
            };
            encoder.writeBuffer(built.uniforms, 0, &[_]Uniforms{uniforms});
        }
    }

    var command = encoder.finish(&.{ .label = label });
    defer command.release();
    core.state().queue.submit(&[_]*gpu.CommandBuffer{command});
}

fn render(entities: *mach.Entities.Mod, card: *Mod) !void {
    const render_pass = if (card.state().render_pass) |rp| rp else std.debug.panic("card.state().render_pass must be specified", .{});
    card.state().render_pass = null;

    // TODO: need a way to specify order of rendering with multiple pipelines
    var q = try entities.query(.{
        .built_pipelines = Mod.read(.built),
        .render_pass_ids = Mod.read(.render_pass_id),
    });
    while (q.next()) |v| {
        for (v.built_pipelines, v.render_pass_ids) |built, render_pass_id| {
            if (render_pass_id != card.state().render_pass_id) continue;

            // Draw the card
            render_pass.setPipeline(built.render);
            // TODO: remove dynamic offsets?
            render_pass.setBindGroup(0, built.bind_group, &.{});
            const total_vertices = 6;
            render_pass.draw(total_vertices, 1, 0, 0);
        }
    }
}

fn update(
    entities: *mach.Entities.Mod,
    core: *mach.Core.Mod,
    card: *Mod,
) !void {
    const device = core.state().device;
    const label = @tagName(name) ++ ".updatePipeline";
    const encoder = device.createCommandEncoder(&.{ .label = label });
    defer encoder.release();

    var q = try entities.query(.{
        .built_pipelines = Mod.read(.built),
        .transforms = Mod.read(.transform),
        .uv_transforms = Mod.read(.uv_transform),
        .sizes = Mod.read(.size),
        .render_pass_ids = Mod.read(.render_pass_id),
    });
    while (q.next()) |v| {
        for (v.built_pipelines, v.transforms, v.uv_transforms, v.sizes, v.render_pass_ids) |built, transform, uv_transform, size, render_pass_id| {
            if (render_pass_id != card.state().render_pass_id) continue;
            encoder.writeBuffer(built.transforms, 0, &[_]math.Mat4x4{transform});
            encoder.writeBuffer(built.uv_transforms, 0, &[_]math.Mat3x3{uv_transform});
            encoder.writeBuffer(built.sizes, 0, &[_]math.Vec2{size});

            var command = encoder.finish(&.{ .label = label });
            defer command.release();
            core.state().queue.submit(&[_]*gpu.CommandBuffer{command});
        }
    }
}
