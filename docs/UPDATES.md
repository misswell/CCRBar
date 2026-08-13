# CCRBar 在线更新

CCRBar 使用 Sparkle 2 检查和安装 GitHub Release 中的 macOS 应用包。

## 应用配置

- 更新源：`https://raw.githubusercontent.com/misswell/CCRBar/master/appcast.xml`
- 检查频率：每天一次，用户也可以从菜单栏或设置页手动检查
- 安装策略：下载后由用户确认，不在后台静默安装
- 更新包：必须是经过 Apple Developer ID 签名并通过公证的 `.zip`
- 更新包签名：使用 Sparkle EdDSA 密钥，私钥只保存在发布机的钥匙串中

## 首次生成签名密钥

Sparkle 的 `generate_keys` 工具只需要运行一次。当前项目使用 `CCRBar` 作为钥匙串账户名：

```bash
generate_keys --account CCRBar
```

命令会输出公钥。公钥可以提交到项目配置，私钥不要提交到 Git，也不要写进 GitHub 仓库。

## 发布新版本

1. 使用 Release 配置构建、签名、公证并装订 `CCRBar.app`，再将它压缩为 `.zip`。
2. 将压缩包上传到对应的 GitHub Release，资产名称保持稳定，例如 `CCRBar-0.2.0-macos.zip`。
3. 使用 Sparkle 的 `generate_appcast` 生成 `appcast.xml`。发布机上可以从钥匙串读取私钥：

   ```bash
   generate_appcast --account CCRBar \
     --download-url-prefix "https://github.com/misswell/CCRBar/releases/download/v0.2.0/" \
     -o appcast.xml \
     path/to/release-archives
   ```

   `path/to/release-archives` 中放要纳入 feed 的发布压缩包。生成结果应覆盖项目根目录的 `appcast.xml`。

4. 检查 `appcast.xml` 中的 `sparkle:edSignature`、版本号、下载地址和文件大小，然后提交并推送 `appcast.xml`。

应用会从 `master` 上的 `appcast.xml` 读取最新版本；因此应先上传 Release 资产，再推送新的 feed。

## 获取 Sparkle 工具

Sparkle 的 Swift Package 本身提供运行时框架。`generate_keys` 和 `generate_appcast` 是 Sparkle 发布包中的命令行工具，可从 [Sparkle Releases](https://github.com/sparkle-project/Sparkle/releases) 下载，或从 Sparkle 源码的 Xcode 工程构建。
