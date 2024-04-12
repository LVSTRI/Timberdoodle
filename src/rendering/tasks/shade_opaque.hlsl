#include <daxa/daxa.inl>
#include "shade_opaque.inl"

#include "shader_lib/visbuffer.glsl"
#include "shader_lib/debug.glsl"
#include "shader_lib/transform.glsl"
#include "shader_lib/depth_util.glsl"
#include "shader_lib/sky_util.glsl"
#include "shader_lib/vsm_util.glsl"


[[vk::push_constant]] ShadeOpaquePush push_opaque;

#define AT_FROM_PUSH deref(push_opaque.attachments).attachments

float compute_exposure(float average_luminance) 
{
    const float exposure_bias = AT_FROM_PUSH.globals->postprocess_settings.exposure_bias;
    const float calibration = AT_FROM_PUSH.globals->postprocess_settings.calibration;
    const float sensor_sensitivity = AT_FROM_PUSH.globals->postprocess_settings.exposure_bias;
    const float ev100 = log2(average_luminance * sensor_sensitivity * exposure_bias / calibration);
	const float exposure = 1.0 / (1.2 * exp2(ev100));
	return exposure;
}

struct AtmosphereLightingInfo
{
    // illuminance from atmosphere along normal vector
    float3 atmosphere_normal_illuminance;
    // illuminance from atmosphere along view vector
    float3 atmosphere_direct_illuminance;
    // direct sun illuminance
    float3 sun_direct_illuminance;
};

float3 get_sun_direct_lighting(daxa_BufferPtr(SkySettings) settings, float3 view_direction, float3 world_position)
{
    const float bottom_atmosphere_intersection_distance = ray_sphere_intersect_nearest(
        float3(0.0, 0.0, length(world_position)),
        view_direction,
        float3(0.0),
        settings->atmosphere_bottom
    );
    bool view_ray_intersects_ground = bottom_atmosphere_intersection_distance >= 0.0;
    const float3 direct_sun_illuminance = view_ray_intersects_ground ? 
        float3(0.0) : 
        get_sun_illuminance(
            settings,
            AT_FROM_PUSH.transmittance,
            AT_FROM_PUSH.globals->samplers.linear_clamp,
            view_direction,
            length(world_position),
            dot(settings->sun_direction, normalize(world_position))
        );
    return direct_sun_illuminance;
}

// ndc going in needs to be in range [-1, 1]
float3 get_view_direction(float2 ndc_xy)
{
    float3 world_direction; 
    if(AT_FROM_PUSH.globals->settings.draw_from_observer == 1)
    {
        const float3 camera_position = AT_FROM_PUSH.globals->observer_camera.position;
        const float4 unprojected_pos = mul(AT_FROM_PUSH.globals->observer_camera.inv_view_proj, float4(ndc_xy, 1.0, 1.0));
        world_direction = normalize((unprojected_pos.xyz / unprojected_pos.w) - camera_position);
    }
    else 
    {
        const float3 camera_position = AT_FROM_PUSH.globals->camera.position;
        const float4 unprojected_pos = mul(AT_FROM_PUSH.globals->camera.inv_view_proj, float4(ndc_xy, 1.0, 1.0));
        world_direction = normalize((unprojected_pos.xyz / unprojected_pos.w) - camera_position);
    }
    return world_direction;
}

float3 hsv2rgb(float3 c) {
    float4 k = float4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
    float3 p = abs(frac(c.xxx + k.xyz) * 6.0 - k.www);
    return c.z * lerp(k.xxx, clamp(p - k.xxx, 0.0, 1.0), c.y);
}

float3 get_vsm_debug_page_color(float2 uv, float depth, float3 world_position)
{
    float3 color = float3(1.0, 1.0, 1.0);

    const float4x4 inv_projection_view = AT_FROM_PUSH.globals->camera.inv_view_proj;
    const bool level_forced = AT_FROM_PUSH.globals->vsm_settings.force_clip_level != 0;
    const int force_clip_level = level_forced ? AT_FROM_PUSH.globals->vsm_settings.forced_clip_level : -1;

    ClipInfo clip_info;
    uint2 render_target_size = AT_FROM_PUSH.globals->settings.render_target_size;
    float real_depth = depth;
    float2 real_uv = uv;
    if(AT_FROM_PUSH.globals->settings.draw_from_observer == 1u)
    {
        const float4 main_cam_proj_world = mul(AT_FROM_PUSH.globals->camera.view_proj, float4(world_position, 1.0));
        const float2 ndc = main_cam_proj_world.xy / main_cam_proj_world.w;
        if(main_cam_proj_world.w < 0.0 || abs(ndc.x) > 1.0 || abs(ndc.y) > 1.0)
        {
            return float3(1.0);
        }
        real_uv = (ndc + float2(1.0)) / float2(2.0);
        real_depth = main_cam_proj_world.z / main_cam_proj_world.w;
    }
    clip_info = clip_info_from_uvs(ClipFromUVsInfo(
        real_uv,
        render_target_size,
        real_depth,
        inv_projection_view,
        force_clip_level,
        AT_FROM_PUSH.vsm_clip_projections,
        AT_FROM_PUSH.vsm_globals,
        AT_FROM_PUSH.globals
    ));
    if(clip_info.clip_level >= VSM_CLIP_LEVELS) { return color; }

    const int3 vsm_page_texel_coords = vsm_clip_info_to_wrapped_coords(clip_info, AT_FROM_PUSH.vsm_clip_projections);
    const uint page_entry = Texture2DArray<uint>::get(AT_FROM_PUSH.vsm_page_table).Load(int4(vsm_page_texel_coords, 0)).r;

    if(get_is_allocated(page_entry))
    {
        const int2 physical_page_coords = get_meta_coords_from_vsm_entry(page_entry);
        const int2 physical_texel_coords = virtual_uv_to_physical_texel(clip_info.clip_depth_uv, physical_page_coords);
        const int2 in_page_texel_coords = int2(_mod(physical_texel_coords, float(VSM_PAGE_SIZE)));
        bool texel_near_border = any(greaterThan(in_page_texel_coords, int2(126))) ||
                                 any(lessThan(in_page_texel_coords, int2(2)));
        if(texel_near_border)
        {
            color = float3(0.001, 0.001, 0.001);
        }
        else
        {
            if(get_is_visited_marked(page_entry)) 
            {
                color.rgb = hsv2rgb(float3(pow(float(vsm_page_texel_coords.z) / float(VSM_CLIP_LEVELS - 1), 0.5), 1.0, 1.0));
            }
            else 
            {
                color.rgb = hsv2rgb(float3(pow(float(vsm_page_texel_coords.z) / float(VSM_CLIP_LEVELS - 1), 0.5), 0.8, 0.2));
            }
        }
    } else {
        color = float3(1.0, 0.0, 0.0);
        if(get_is_dirty(page_entry)) {color = float3(0.0, 0.0, 1.0);}
    }
    return color;
}

int get_height_depth_offset(int3 vsm_page_texel_coords)
{
    const int page_draw_camera_height = Texture2DArray<int>::get(AT_FROM_PUSH.vsm_page_height_offsets).Load(int4(vsm_page_texel_coords, 0)).r;
    const int current_camera_height = deref_i(AT_FROM_PUSH.vsm_clip_projections, vsm_page_texel_coords.z).height_offset;
    const int height_difference = current_camera_height - page_draw_camera_height;
    return height_difference;
}

float get_vsm_shadow(float2 uv, float depth, float3 world_position, float sun_norm_dot)
{
    const bool level_forced = AT_FROM_PUSH.globals->vsm_settings.force_clip_level != 0;
    const int force_clip_level = level_forced ? AT_FROM_PUSH.globals->vsm_settings.forced_clip_level : -1;

    const float4x4 inv_projection_view = AT_FROM_PUSH.globals->camera.inv_view_proj;
    uint2 render_target_size = AT_FROM_PUSH.globals->settings.render_target_size;
    ClipInfo clip_info;
    float real_depth = depth;
    float2 real_uv = uv;
    if(AT_FROM_PUSH.globals->settings.draw_from_observer == 1u)
    {
        const float4 main_cam_proj_world = mul(AT_FROM_PUSH.globals->camera.view_proj, float4(world_position, 1.0));
        const float2 ndc = main_cam_proj_world.xy / main_cam_proj_world.w;
        real_uv = (ndc + float2(1.0)) / float2(2.0);
        real_depth = main_cam_proj_world.z / main_cam_proj_world.w;
    }
    clip_info = clip_info_from_uvs(ClipFromUVsInfo(
        real_uv,
        render_target_size,
        real_depth,
        inv_projection_view,
        force_clip_level,
        AT_FROM_PUSH.vsm_clip_projections,
        AT_FROM_PUSH.vsm_globals,
        AT_FROM_PUSH.globals
    ));
    if(clip_info.clip_level >= VSM_CLIP_LEVELS) { return 1.0; }

    const int3 vsm_page_texel_coords = vsm_clip_info_to_wrapped_coords(clip_info, AT_FROM_PUSH.vsm_clip_projections);
    const uint page_entry = Texture2DArray<uint>::get(AT_FROM_PUSH.vsm_page_table).Load(int4(vsm_page_texel_coords, 0)).r;

    if(get_is_allocated(page_entry))
    {
        const int2 physical_page_coords = get_meta_coords_from_vsm_entry(page_entry);
        const int2 physical_texel_coords = virtual_uv_to_physical_texel(clip_info.clip_depth_uv, physical_page_coords);
        const int2 in_page_texel_coords = int2(_mod(physical_texel_coords, float(VSM_PAGE_SIZE)));

        const float vsm_sample = Texture2D<float>::get(AT_FROM_PUSH.vsm_memory_block).Load(int3(physical_texel_coords, 0)).r;

        const float4x4 vsm_shadow_view = deref_i(AT_FROM_PUSH.vsm_clip_projections, clip_info.clip_level).camera.view;
        const float4x4 vsm_shadow_proj = deref_i(AT_FROM_PUSH.vsm_clip_projections, clip_info.clip_level).camera.proj;

        const float3 view_projected_world_pos = (mul(vsm_shadow_view, daxa_f32vec4(world_position, 1.0))).xyz;

        const int height_offset = get_height_depth_offset(vsm_page_texel_coords);

        const float view_space_offset = 0.004 * pow(2, clip_info.clip_level) / max(abs(sun_norm_dot), 0.7);
        // const float view_space_offset = 0.002 * pow(2, clip_info.clip_level) / max(abs(sun_norm_dot), 0.05);
        const float fp_remainder = frac(view_projected_world_pos.z) + view_space_offset;
        const int int_part = daxa_i32(floor(view_projected_world_pos.z));
        const int modified_view_depth = int_part + height_offset;
    
        const float3 offset_view_pos = float3(view_projected_world_pos.xy, float(modified_view_depth) + fp_remainder);

        const float4 vsm_projected_world = mul(vsm_shadow_proj, float4(offset_view_pos, 1.0));
        const float vsm_projected_depth = vsm_projected_world.z / vsm_projected_world.w;

        const float page_offset_projected_depth = get_page_offset_depth(clip_info, vsm_projected_depth, AT_FROM_PUSH.vsm_clip_projections);
        const bool is_in_shadow = vsm_sample < page_offset_projected_depth;
        return is_in_shadow ? 0.0 : 1.0;
    }
    return 1.0;
}


[numthreads(SHADE_OPAQUE_WG_X, SHADE_OPAQUE_WG_Y, 1)]
[shader("compute")]
void main(
    uint3 svdtid : SV_DispatchThreadID
)
{
    let push = push_opaque;
    const int2 index = svdtid.xy;
    const float2 screen_uv = float2(svdtid.xy) * AT_FROM_PUSH.globals->settings.render_target_size_inv;

    const float3 atmo_camera_position = AT_FROM_PUSH.globals->settings.draw_from_observer == 1 ? 
        AT_FROM_PUSH.globals->observer_camera.position * M_TO_KM_SCALE :
        AT_FROM_PUSH.globals->camera.position * M_TO_KM_SCALE;
    const float3 bottom_atmo_offset = float3(0,0, AT_FROM_PUSH.globals->sky_settings.atmosphere_bottom + BASE_HEIGHT_OFFSET);
    const float3 bottom_atmo_offset_camera_position = atmo_camera_position + bottom_atmo_offset;

    if(all(equal(index, int2(0))))
    {
        AT_FROM_PUSH.globals->debug->gpu_output.debug_ivec4.x = int(AT_FROM_PUSH.instantiated_meshlets->first_count);
        AT_FROM_PUSH.globals->debug->gpu_output.debug_ivec4.y = int(AT_FROM_PUSH.instantiated_meshlets->second_count);
    }
    const uint triangle_id = Texture2D<uint>::get(AT_FROM_PUSH.vis_image).Load(int3(index, 0), int2(0)).x;
    float4 output_value = float4(0);
    float4 debug_value = float4(0);

    if(triangle_id != INVALID_TRIANGLE_ID)
    {
        float4x4 view_proj;
        float3 camera_position;
        if(AT_FROM_PUSH.globals->settings.draw_from_observer == 1)
        {
            view_proj = AT_FROM_PUSH.globals->observer_camera.view_proj;
            camera_position = AT_FROM_PUSH.globals->observer_camera.position;
        }
        else 
        {
            view_proj = AT_FROM_PUSH.globals->camera.view_proj;
            camera_position = AT_FROM_PUSH.globals->camera.position;
        }

        daxa_BufferPtr(MeshletInstancesBufferHead) instantiated_meshlets = AT_FROM_PUSH.instantiated_meshlets;
        daxa_BufferPtr(GPUMesh) meshes = AT_FROM_PUSH.meshes;
        daxa_BufferPtr(daxa_f32mat4x3) combined_transforms = AT_FROM_PUSH.combined_transforms;
        VisbufferTriangleData tri_data = visgeo_triangle_data(
            triangle_id,
            float2(index),
            push.size,
            push.inv_size,
            view_proj,
            instantiated_meshlets,
            meshes,
            combined_transforms
        );
        float3 normal = tri_data.world_normal;
        GPUMaterial material;
        material.diffuse_texture_id.value = 0;
        material.normal_texture_id.value = 0;
        material.roughnes_metalness_id.value = 0;
        material.alpha_discard_enabled = false;
        material.normal_compressed_bc5_rg = false;
        if(tri_data.meshlet_instance.material_index != INVALID_MANIFEST_INDEX)
        {
            material = AT_FROM_PUSH.material_manifest[tri_data.meshlet_instance.material_index];
        }

        float3 albedo = float3(0.5f);
        if(material.diffuse_texture_id.value != 0)
        {
            albedo = Texture2D<float>::get(material.diffuse_texture_id).SampleGrad(
                SamplerState::get(AT_FROM_PUSH.globals->samplers.linear_repeat_ani),
                tri_data.uv, tri_data.uv_ddx, tri_data.uv_ddy
            ).rgb;
        }

        if(material.normal_texture_id.value != 0)
        {
            float3 normal_map_value = float3(0);
            if(material.normal_compressed_bc5_rg)
            {
                const float2 raw = Texture2D<float>::get(material.normal_texture_id).SampleGrad(
                    SamplerState::get(AT_FROM_PUSH.globals->samplers.normals),
                    tri_data.uv, tri_data.uv_ddx, tri_data.uv_ddy
                ).rg;
                const float2 rescaled_normal_rg = raw * 2.0f - 1.0f;
                const float normal_b = sqrt(clamp(1.0f - dot(rescaled_normal_rg, rescaled_normal_rg), 0.0, 1.0));
                normal_map_value = float3(rescaled_normal_rg, normal_b);
            }
            else
            {
                const float3 raw = Texture2D<float>::get(material.normal_texture_id).SampleGrad(
                    SamplerState::get(AT_FROM_PUSH.globals->samplers.normals),
                    tri_data.uv, tri_data.uv_ddx, tri_data.uv_ddy
                ).rgb;
                normal_map_value = raw * 2.0f - 1.0f;
            }
            const float3x3 tbn = transpose(float3x3(-tri_data.world_tangent, -cross(tri_data.world_tangent, tri_data.world_normal), tri_data.world_normal));
            normal = mul(tbn, normal_map_value);
        }

        const float3 sun_direction = AT_FROM_PUSH.globals->sky_settings.sun_direction;
        const float sun_norm_dot = clamp(dot(normal, sun_direction), 0.0, 1.0);
        const float vsm_shadow = get_vsm_shadow(screen_uv, tri_data.depth, tri_data.world_position, sun_norm_dot);
        const float final_shadow = sun_norm_dot * vsm_shadow;

        const float3 atmo_camera_position = AT_FROM_PUSH.globals->camera.position * M_TO_KM_SCALE;

        const float3 direct_lighting = final_shadow * get_sun_direct_lighting(AT_FROM_PUSH.globals->sky_settings_ptr, sun_direction, bottom_atmo_offset_camera_position);
        const float4 compressed_indirect_lighting = TextureCube<float>::get(AT_FROM_PUSH.sky_ibl).SampleLevel(SamplerState::get(AT_FROM_PUSH.globals->samplers.linear_clamp), normal, 0);
        const float3 indirect_lighting = compressed_indirect_lighting.rgb * compressed_indirect_lighting.a;
        const float3 lighting = direct_lighting + indirect_lighting;

        const bool visualize_clip_levels = AT_FROM_PUSH.globals->vsm_settings.visualize_clip_levels == 1;
        const float3 vsm_debug_color = visualize_clip_levels ? get_vsm_debug_page_color(screen_uv, tri_data.depth, tri_data.world_position) : float3(1.0f);
        output_value.rgb = albedo.rgb * lighting * vsm_debug_color;
        debug_value.xyz = indirect_lighting;
    }
    else 
    {
        const float2 ndc_xy = screen_uv * 2.0 - 1.0;
        const float3 view_direction = get_view_direction(ndc_xy);
        const float3 atmosphere_direct_illuminnace = get_atmosphere_illuminance_along_ray(
            AT_FROM_PUSH.globals->sky_settings_ptr,
            AT_FROM_PUSH.transmittance,
            AT_FROM_PUSH.sky,
            AT_FROM_PUSH.globals->samplers.linear_clamp,
            view_direction,
            bottom_atmo_offset_camera_position
        );
        const float3 sun_direct_illuminance = get_sun_direct_lighting(AT_FROM_PUSH.globals->sky_settings_ptr, view_direction, bottom_atmo_offset_camera_position);
        const float3 total_direct_illuminance = sun_direct_illuminance + atmosphere_direct_illuminnace;
        output_value.rgb = total_direct_illuminance;
        debug_value.xyz = atmosphere_direct_illuminnace;
    }

    const float exposure = compute_exposure(deref(AT_FROM_PUSH.luminance_average));
    const float3 exposed_color = output_value.rgb * exposure;
    debug_write_lens(
        AT_FROM_PUSH.globals->debug,
        AT_FROM_PUSH.debug_lens_image,
        index,
        debug_value
    );
    RWTexture2D<float>::get(AT_FROM_PUSH.color_image)[index] = float4(exposed_color, output_value.a);
}