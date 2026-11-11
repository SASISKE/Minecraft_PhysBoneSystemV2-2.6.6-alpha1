# PhysBone System V2 — alpha 2.6.6-alpha.1

An experimental secondary-bone system for Figura avatars. The editor is currently in Russian. It is inspired by VRChat PhysBones but does not implement the same formulas or value ranges. Expect bugs and potentially substantial FPS loss; test on a copy of your avatar first.

## Install

1. Install Minecraft and Figura and confirm your avatar already loads. The live test used Minecraft 1.21.11 with NoFigura 0.1.6.9; compatibility with standard Figura or other versions has not been independently verified.
   Give different avatars and test copies distinct `name` values in `avatar.json`: matching names can share and overwrite the same local PhysBone profile.
2. Copy **all Lua files inside `runtime`** to the root of your avatar folder, next to `avatar.json` and the existing scripts. Do not nest the `runtime` folder. Back up any files with the same names before replacing them.
3. Check `avatar.json` **before changing it**. If `autoScripts` exists, add `physics_bone_loader` to that array without removing or reordering existing entries, for example:

   ```json
   "autoScripts": ["script", "physics_bone_loader"]
   ```

   If `autoScripts` is absent, Figura automatically runs every original Lua script. Before installing, record all existing `.lua` paths and include **all of them** in a new `autoScripts` array followed by `physics_bone_loader`. Remove `.lua` and replace folder separators with dots: `libs/animation.lua` becomes `libs.animation`. If the avatar had no scripts, `["physics_bone_loader"]` is enough. Do not add the other PhysBone `runtime` files to the array; the loader imports them. The previous automatic execution order was undefined, so test scripts that depend on ordering. See [Figura's metadata documentation](https://docs.figuramc.org/tutorials/Avatar-Metadata#autoscripts--string).
4. Select/reload the avatar in Figura and open the editor with **F8**. Check Figura's errors and key bindings if it does not open.

## First chain

The model must have separately transformable groups with distinct pivots. A single mesh cannot be turned into a physical chain by this script.

1. In the left Outliner select the first group of a tail or ear and choose **Создать PhysBone** (create PhysBone).
2. Resolve branch choices and, if needed, set **Конечная точка** to the manual endpoint and specify its vector.
3. Choose **Тип** (type) and a **Стартовый профиль** (starter preset), then click **Применить профиль к компоненту** (apply). This replaces the component's settings. Tune the controls gradually; **Подробнее** opens advanced controls and the right panel scrolls.
4. Load the avatar in its usual pose, test motion and your animations, then click **Сохранить** (save). Each ear can use its own component. **Shift + `** toggles bone gizmos.

On the **Производительность** (performance) page, the performance mode reduces simulation quality/work but does not guarantee a high frame rate. Start with one short chain; contacts add cost.

## Collisions and sharing

Contacts are disabled by default. Add and position a sphere or capsule on **Коллайдеры** (colliders), then enable **Физические контакты** and the desired avatar/world/self-contact options for the chain. Body and block tests use chain points, so the middle of a long bone can cross thin obstacles; fast motion and exhausted budgets can miss contacts too.

To bundle your setup with your avatar, choose **Экспортировать профиль v2** in F8, grant Figura File API access if needed, and copy the generated `physics_bone_preset.lua` from `figura/data/PhysicsBoneV2/Characters/…` to the avatar root. Share your avatar with its model, `avatar.json`, PhysBone Lua files and preset. Existing local Figura Config takes precedence; to replace it, choose **Загрузить physics_bone_preset.lua**, review and save. The profile contains paths for that particular model.

To disable the system, remove `physics_bone_loader` from `autoScripts` and reload the avatar. Saved Figura data is not deleted by this action.

This alpha scans one model hierarchy; groups in another top-level model or outside the selected `root` may not appear in the Outliner. The alpha has not been accepted across different rigs, all animations, first-person views, collision cases or profile-transfer workflows. NoFigura reported **456.99 KiB** for the test avatar with this alpha; standard Figura documentation mentions a **100 KB** limit. A locally working avatar may therefore fail to upload to a standard Figura server. Check the final size and upload on your own setup; delivery to other viewers has not been verified. See [Figura's file format documentation](https://docs.figuramc.org/start_here/Avatar%20File%20Format). The simulation is client-side and may differ between viewers. Item/hand attachments, armor and animation authoring are outside this package.
