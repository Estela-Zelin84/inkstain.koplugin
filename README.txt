InkStain GitHub 全自动发布端

把以下 3 个文件按原路径加入仓库：
  .github/workflows/release.yml
  scripts/build_release.py
  scripts/verify_release.py

之后正式发布只需要：
1. _meta.lua 中 version 改为目标版本，例如 3.5.7
2. 合并代码到 main
3. 创建并推送 tag：v3.5.7

GitHub Actions 会自动：
- 核对 tag 与 _meta.lua 版本
- 生成 inkstain.koplugin-v3.5.7.zip
- 生成 update.json
- 校验 ZIP 目录、版本、大小和 SHA-256
- 创建/更新 v3.5.7 Release
- 从公网重新下载 ZIP 验证
- 创建/更新 stable-channel Release
- 上传 stable-channel/update.json
- 再次从公网验证 update.json

注意：OTA 客户端 ota_config.lua 指向 Estela-Zelin84/inkstain.koplugin，
因此正式 OTA 必须由上游仓库合并这些发布文件并在上游创建 tag 后生效。
