"""Export the in-app SceneKit hero's Keycap.usdz from the Wave5 keycap blend.

Companion to export-keycap.py (which exports the web GLB). The in-app hero
(App/KeycapHeroView.swift) loads App/Resources/Keycap.usdz in SceneKit and
supplies its own camera + lighting, so the USDZ only needs the keycap + legend
geometry with the baked PBR materials — exactly the scene export-keycap.py
builds. This script runs that script's setup verbatim (open blend, bake
albedo/roughness/normal, rebuild materials, select the three objects), then
exports USD instead of glTF.

512px textures (usdz_downscale_size) keep the asset ~0.75 MB; the 2048 bake is
web-GLB detail the small SceneKit hero doesn't need. Y-up + USDPreviewSurface
so SceneKit reads it, matching the previously shipped asset's structure.

Run (after regenerating the Wave5 legend, e.g. for a font change):
    blender --background --python site/scripts/export-keycap-usdz.py
"""

import os

import bpy

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "export-keycap.py")
REPO = os.path.dirname(os.path.dirname(HERE))
USDZ = os.path.join(REPO, "App", "Resources", "Keycap.usdz")

# Run export-keycap.py up to (not including) its glTF export: opens the blend,
# bakes textures, rebuilds materials, and leaves keycap+decal+fringe selected.
src = open(SRC).read()
head = src[: src.index("bpy.ops.export_scene.gltf(")]
ns = {"__name__": "export_keycap_head", "__file__": SRC}
exec(compile(head, SRC, "exec"), ns)

bpy.ops.wm.usd_export(
    filepath=USDZ,
    selected_objects_only=True,
    export_animation=False,
    export_normals=True,
    export_materials=True,
    generate_preview_surface=True,
    convert_orientation=True,
    export_global_forward_selection="NEGATIVE_Z",
    export_global_up_selection="Y",
    export_textures_mode="NEW",
    overwrite_textures=True,
    root_prim_path="/Keycap",
    usdz_downscale_size="512",
)
print("USDZ exported:", USDZ, os.path.getsize(USDZ), "bytes")
