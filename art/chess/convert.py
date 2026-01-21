import bpy
import os

# --- Configuration ---
# Change this to your target directory (e.g., "C:/Projects/Chess/Art")
target_directory = "/Users/woodj/chess/art/chess"

def reset_blend_file():
    """Clears all objects from the current scene to ensure a clean export."""
    bpy.ops.wm.read_factory_settings(use_empty=True)

def convert_fbx_to_glb(directory):
    """Recursively finds and converts FBX files to GLB."""
    for root, dirs, files in os.walk(directory):
        for file in files:
            if file.lower().endswith(".fbx"):
                fbx_path = os.path.join(root, file)
                glb_path = os.path.splitext(fbx_path)[0] + ".glb"

                print(f"Converting: {fbx_path}")

                # 1. Clear the scene before each import
                reset_blend_file()

                # 2. Import FBX
                # Note: 'use_manual_orientation' can help fix rotation issues
                bpy.ops.import_scene.fbx(filepath=fbx_path)

                # 3. Export as GLB (glTF 2.0)
                # 'export_format' can be 'GLB' or 'GLTF_SEPARATE'
                bpy.ops.export_scene.gltf(
                    filepath=glb_path,
                    export_format='GLB',
                    use_selection=False
                )

                print(f"Saved to: {glb_path}")

if __name__ == "__main__":
    # Ensure the directory exists
    if os.path.exists(target_directory):
        convert_fbx_to_glb(target_directory)
        print("Conversion complete!")
    else:
        print(f"Error: Directory '{target_directory}' does not exist.")
