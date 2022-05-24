# KbsyncTool

Grab kbsync dynamically from your jailbroken iOS device.


## Usage

```shell
Test1:~ root# kbsynctool -s 9000
[DEBUG] Did open IPv4 listening socket 3
[DEBUG] Did open IPv6 listening socket 4
[INFO] GCDWebServer started on port 9000 and reachable at http://192.168.101.227:9000/
2022-05-10 13:35:05.486 kbsynctool[11264:1055758] Using -s http://192.168.101.227:9000/ with NyaMisty/ipatool-py...
```

Then use [ipatool-py](https://github.com/NyaMisty/ipatool-py) to send requests.


## Troubleshoot

1. **Disable** “Use Face ID for iTunes & App Store” in “Settings, Face ID & Passcode”.
2. Download one or two items in App Store before fetch credentials.
3. Select **Save Password for Free Items** if asked to do so.
4. Select **Require After 15 Minutes** if asked to do so.
