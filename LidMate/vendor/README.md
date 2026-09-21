# vendor/

LidMate 需要在 App 包里捆绑两个第三方二进制。出于仓库体积和许可证清晰度的
考虑，**建议不要把它们提交进 Git**（`.gitignore` 里已经排除），而是让使用者
自行获取，或者放在 Release 附件里。

构建前把这两个文件放到本目录：

## m1ddc（Apple Silicon 专用）

```bash
git clone --depth 1 https://github.com/waydabber/m1ddc
cd m1ddc && make
cp m1ddc /path/to/LidMate/vendor/m1ddc
```

## displayplacer

```bash
curl -L -o vendor/displayplacer \
  https://github.com/jakehilborn/displayplacer/releases/download/v1.4.0/displayplacer-apple-v140
chmod +x vendor/displayplacer
```

两者均为 MIT 许可，详见仓库根目录的 `THIRD-PARTY-NOTICES.md`。
