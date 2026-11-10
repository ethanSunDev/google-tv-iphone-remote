# Google TV 遥控器

原生 SwiftUI App，面向 iOS 16 及以上的 iPhone。用 Google TV 屏幕上的 6 位码配对，通过家庭局域网发送方向键、确定、返回、主页、播放/暂停、音量、静音和电源指令。电视需支持 Android TV Remote Service v2。电视深度待机后能否唤醒取决于型号和待机联网设置。

## 用 Windows 编译并装到 iPhone

1. 把本目录的**内容**放到你自己的 GitHub 仓库默认分支的根目录，保留 `.github/workflows/build-ios.yml`。可以用私有仓库。GitHub Actions 使用 macOS runner 编译，流程不需要 Apple 账号或签名密钥。
2. 在仓库的 **Actions** 中选择 **Build iPhone IPA → Run workflow**。运行成功后下载 `TVRemote-unsigned`，解压得到 `TVRemote.ipa`。
3. 按 [AltStore Classic Windows 安装说明](https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows) 安装 AltServer，并用 USB 将 AltStore 装到 iPhone。按 iPhone 提示完成设备信任和开发者模式设置。
4. 把 `TVRemote.ipa` 传到 iPhone 的「文件」。在 AltStore 中打开 **My Apps → +**，选择该文件，用你的 Apple 账号签名安装。免费签名通常每 7 天刷新一次，可让 iPhone 和运行 AltServer 的 Windows 电脑在同一局域网时刷新。参见 [AltStore 使用说明](https://faq.altstore.io/altstore-classic/your-altstore)。

## 连接电视

1. 打开电视，在 Google TV 的「设置 → 网络和互联网」里查看当前连接的 IP 地址。iPhone 接入同一局域网。
2. 打开「电视遥控器」，允许「本地网络」访问。输入电视 IP，点「连接」。
3. 输入电视屏幕上的 6 位配对码，点「确认配对」。显示「已连接」后，先试方向键和返回键。以后打开 App 会尝试连接上次配对的地址。
4. 电视 IP 更改时，断开后输入新地址。电视提示配对或先前的连接失效时，点「重新配对」。

项目通过 Swift Package Manager 引用 [AndroidTVRemoteControl 2.4.16](https://github.com/odyshewroman/AndroidTVRemoteControl/tree/2.4.16)。遥控身份的私钥在 iPhone 上生成并保存在钥匙串，IPA 内没有配对私钥。
