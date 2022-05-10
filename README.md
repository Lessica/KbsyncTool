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
