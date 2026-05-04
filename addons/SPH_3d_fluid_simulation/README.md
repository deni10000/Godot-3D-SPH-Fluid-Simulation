## How to Use

1. **Add the Scene**: Instance the `fluid_simulation.tscn` into your main scene.
2. **Enable Editing**: Right-click on the instanced node and select **"Editable Children"**.
3. **Setup Obstacles**: Add your collision geometry (polygons/meshes) and ensure they are set to **Layer 10**.
4. **Bake SDF**:
    - Select the `GPUParticlesCollisionSDF3D` node within the hierarchy.
    - In the inspector, click the **"Bake"** button to generate the Signed Distance Field (SDF) data for GPU collisions.