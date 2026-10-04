# audio1 回退 manifest

`runtime-manifest.json` 是默认设备跟随版本启用前的精确 audio1 bootstrap manifest 快照，供维护工具核验已有 immutable audio1 runtime。它锁定原始上游 DMG/sourceVerification 字节和 audio1 的已签名 `winecoreaudio.so`（SHA-256 `90419c1a4009407b28b353614b883ef3d1531e8b852416fe0eaf704c90b6fce0`）。

正式 manifest 已提升到 `audio-default-following-20261004`；该快照不会进入产品 bundle，也不会成为默认版本。catalog 保留 audio1 engine 作为非默认 rollback。不要改写这份历史 manifest 来指向新音频模块；如果上游基础 runtime 身份改变，应新建对应版本记录。
