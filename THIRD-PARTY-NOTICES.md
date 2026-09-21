# 第三方依赖与许可

LidMate 自身以 MIT 许可发布。它**在安装包内捆绑**了下面两个第三方命令行
工具（二进制形式），以便开箱即用。两者都是 MIT 许可，允许再分发，但要求
保留版权声明 —— 本文件即是该声明。

---

## m1ddc

- 用途：在 Apple Silicon Mac 上通过 DDC/CI 读写外接显示器参数
- 来源：https://github.com/waydabber/m1ddc
- 许可：MIT

```
MIT License

Copyright (c) waydabber

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## displayplacer

- 用途：从命令行配置 macOS 的多显示器排列/镜像
- 来源：https://github.com/jakehilborn/displayplacer
- 许可：MIT

```
MIT License

Copyright (c) Jake Hilborn

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## 重新获取二进制

`vendor/` 目录下的二进制是可选的（见 `vendor/README.md`）。如果你要自己编译：

```bash
# m1ddc
git clone https://github.com/waydabber/m1ddc && cd m1ddc && make

# displayplacer
curl -L -o displayplacer \
  https://github.com/jakehilborn/displayplacer/releases/download/v1.4.0/displayplacer-apple-v140
chmod +x displayplacer
```
