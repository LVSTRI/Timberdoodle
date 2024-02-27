#include <daxa/daxa.inl>

#include "cull_meshes.inl"
#include "shader_shared/cull_util.inl"

#define DEBUG_MESH_CULL 0
#define DEBUG_MESH_CULL1 0

#extension GL_EXT_debug_printf : enable

// #if defined(CullMeshesCommand_COMMAND)
// layout(local_size_x = 1) in;
// DAXA_DECL_PUSH_CONSTANT(CullMeshesCommandPush, push)
// void main()
// {
//     const uint entity_count = deref(push.uses.entity_meta).entity_count;
//     const uint dispatch_x = (entity_count + CULL_MESHES_WORKGROUP_X - 1) / CULL_MESHES_WORKGROUP_X;
//     deref(push.uses.command).x = dispatch_x;
//     deref(push.uses.command).y = 1;
//     deref(push.uses.command).z = 1;
// }
// #else
DAXA_DECL_PUSH_CONSTANT(CullMeshesPush, push)
layout(local_size_x = CULL_MESHES_WORKGROUP_X, local_size_y = CULL_MESHES_WORKGROUP_Y) in;
void main()
{
    uint mesh_draw_index = gl_GlobalInvocationID.x;
    uint opaque_draw_list_index = 0;
    // We do a single dispatch to cull both lists, the shader threads simply check if their id overruns the first list,
    // then assign themselves to an element in the second list.
    if (mesh_draw_index >= deref(push.uses.opaque_mesh_draw_lists).list_sizes[0])
    {
        mesh_draw_index -= deref(push.uses.opaque_mesh_draw_lists).list_sizes[0];
        opaque_draw_list_index = 1;
    }
    else
    {
    }
    // As the dispatch thread count is a multiple of CULL_MESHES_WORKGROUP_X, there will also be threads overstepping
    // the second draw list.
    if (mesh_draw_index >= deref(push.uses.opaque_mesh_draw_lists).list_sizes[1])
    {
        // debugPrintfEXT("out mesh_draw_index > list1 count: %i > %i\n", mesh_draw_index, deref(push.uses.opaque_mesh_draw_lists).list_sizes[1]);
        return;
    }

    const MeshDrawTuple mesh_draw = deref(deref(push.uses.opaque_mesh_draw_lists).mesh_draw_tuples[opaque_draw_list_index][mesh_draw_index]);
    const uint meshlet_count = deref(push.uses.meshes[mesh_draw.mesh_index]).meshlet_count;
    if (meshlet_count == 0)
    {
        return;
    }

    // How does this work?
    // - this is an asymertric work distribution problem
    // - each mesh cull thread needs x followup threads where x is the number of meshlets for the mesh
    // - writing x times to some argument buffer to dispatch over later is extreamly divergent and inefficient
    //   - solution is to combine writeouts in powers of two:
    //   - instead of x writeouts, only do log2(x), one writeout per set bit in the meshletcount.
    //   - when you want to write out 17 meshlet work units, instead of writing 7 args into a buffer,
    //     you write one 1x arg, no 2x arg, no 4x arg, no 8x arg and one 16x arg. the 1x and the 16x args together contain 17 work units.
    // - still not good enough, in large cases like 2^16 - 1 meshlets it would need 15 writeouts, that is too much!
    //   - solution is to limit the writeouts to some smaller number (i chose 5, as it has a max thread waste of < 5%)
    //   - A strong compromise is to round up invocation count from meshletcount in such a way that the round up value only has 4 bits set at most.
    //   - as we do one writeout per bit set in meshlet count, this limits the writeout to 5.
    // - in worst case this can go down from thousands of divergent writeouts down to 5 while only wasting < 5% of invocations.
    const uint material_index = deref(push.uses.meshes[mesh_draw.mesh_index]).material_index;
    GPUMaterial material = deref(push.uses.materials[material_index]);
    daxa_RWBufferPtr(MeshletCullArgBucketsBufferHead) cull_buckets = 
        opaque_draw_list_index == 0 ? 
        push.uses.meshlet_cull_arg_buckets_opaque :
        push.uses.meshlet_cull_arg_buckets_discard;
        
    const uint MAX_BITS = 5;
    uint meshlet_count_msb = findMSB(meshlet_count);
    const uint shift = uint(max(0, int(meshlet_count_msb) + 1 - int(MAX_BITS)));
    // clip off all bits below the 5 most significant ones.
    uint clipped_bits_meshlet_count = (meshlet_count >> shift) << shift;
    // Need to round up if there were bits clipped.
    if (clipped_bits_meshlet_count < meshlet_count)
    {
        clipped_bits_meshlet_count += (1 << shift);
    }
    // Now bit by bit, do one writeout of an indirect command:
    uint bucket_bit_mask = clipped_bits_meshlet_count;
    // Each time we write out a command we add on the number of meshlets processed by that arg.
    uint meshlet_offset = 0;
    while (bucket_bit_mask != 0)
    {
        const uint bucket_index = findMSB(bucket_bit_mask);
        const uint indirect_arg_meshlet_count = 1 << (bucket_index);
        // Mask out bit.
        bucket_bit_mask &= ~indirect_arg_meshlet_count;
        const uint arg_array_offset = atomicAdd(deref(cull_buckets).indirect_arg_counts[bucket_index], 1);
        // Update indirect args for meshlet cull
        {
            const uint threads_per_indirect_arg = 1 << bucket_index;

            const uint work_group_size = (deref(push.uses.globals).settings.enable_mesh_shader == 1) ? TASK_SHADER_WORKGROUP_X : CULL_MESHLETS_WORKGROUP_X;
            const uint prev_indirect_arg_count = arg_array_offset;
            const uint prev_needed_threads = threads_per_indirect_arg * prev_indirect_arg_count;
            const uint prev_needed_workgroups = (prev_needed_threads + work_group_size - 1) / work_group_size;
            const uint cur_indirect_arg_count = arg_array_offset + 1;
            const uint cur_needed_threads = threads_per_indirect_arg * cur_indirect_arg_count;
            const uint cur_needed_workgroups = (cur_needed_threads + work_group_size - 1) / work_group_size;

            const bool update_cull_meshlets_dispatch = prev_needed_workgroups != cur_needed_workgroups;
            if (update_cull_meshlets_dispatch)
            {
                atomicMax(deref(cull_buckets).commands[bucket_index].x, cur_needed_workgroups);
            }
        }
        MeshletCullIndirectArg arg;
        arg.entity_index = mesh_draw.entity_index;
        arg.mesh_index = mesh_draw.mesh_index;
        arg.material_index = material_index;
        arg.in_mesh_group_index = mesh_draw.in_mesh_group_index;
        arg.meshlet_indices_offset = meshlet_offset;
        arg.meshlet_count = min(meshlet_count - meshlet_offset, indirect_arg_meshlet_count);
        deref(deref(cull_buckets).indirect_arg_ptrs[bucket_index][arg_array_offset]) = arg;
        meshlet_offset += indirect_arg_meshlet_count;
    }
}
//#endif
