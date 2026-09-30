#!/usr/bin/env python3
"""control 文件自检：模拟 dpkg 的控制文件解析规则，抓出会让 deb 装不上的写法。

dpkg 解析规则（踩过的坑）：
  * 字段行 = `Key: value`，Key 只能由可打印 ASCII 组成、**不含空格**；
  * 字段的续行**必须以空格或 TAB 开头**（`Description:` 的长文本尤其容易漏）；
  * 漏了前导空格的续行会被当成新字段名 → 报
        field name 'xxx' must be followed by colon
    整个包直接被 dpkg 拒绝，安装必失败（这就是 2.3.15 装不上的原因）。

用法：
    python3 check_control.py                 # 校验 ./control
    python3 check_control.py <control 路径>
    python3 check_control.py --deb <x.deb>   # 校验打包后的 deb 里的 control
退出码 0 = 通过，1 = 有问题。
"""
import gzip
import io
import lzma
import re
import struct
import sys
import tarfile


def control_from_deb(deb_path):
    """从 deb（ar 归档）里取出 control 文件的原始字节，纯标准库实现。"""
    b = open(deb_path, 'rb').read()
    if b[:8] != b'!<arch>\n':
        raise ValueError('不是 ar 归档（缺 !<arch>\\n magic）')
    p = 8
    while p + 60 <= len(b):
        name = b[p:p + 16].decode('latin1').strip().rstrip('/')
        size = int(b[p + 48:p + 58].decode('latin1').strip())
        body = b[p + 60:p + 60 + size]
        p += 60 + size + (size % 2)
        if not name.startswith('control.tar'):
            continue
        if body[:2] == b'\x1f\x8b':
            body = gzip.decompress(body)
        elif body[:6] == b'\xfd7zXZ\x00':
            body = lzma.decompress(body)
        tf = tarfile.open(fileobj=io.BytesIO(body))
        for m in tf.getmembers():
            if m.name.lstrip('./') == 'control':
                return tf.extractfile(m).read()
        raise ValueError('control.tar 里没有 control 文件')
    raise ValueError('ar 归档里没有 control.tar*')


if len(sys.argv) >= 3 and sys.argv[1] == '--deb':
    path = sys.argv[2]
    try:
        raw = control_from_deb(path)
    except Exception as exc:                                  # noqa: BLE001
        print('!! 无法从 %s 取出 control: %s' % (path, exc))
        sys.exit(1)
else:
    path = sys.argv[1] if len(sys.argv) > 1 else 'control'
    try:
        raw = open(path, 'rb').read()
    except OSError as exc:
        print('!! 读不到 %s: %s' % (path, exc))
        sys.exit(1)

try:
    text = raw.decode('utf-8')
except UnicodeDecodeError as exc:
    print('!! control 不是合法 UTF-8: %s' % exc)
    sys.exit(1)

bad = []
seen_field = False
for i, line in enumerate(text.split('\n'), 1):
    if line == '':
        continue                       # 尾随换行/空行本身不算错
    if line[0] in (' ', '\t'):
        if not seen_field:
            bad.append((i, '续行出现在任何字段之前', line))
        continue                       # 合法续行
    m = re.match(r'^([!-9;-~]+):', line)
    if not m:
        # 既不是合法字段名，又没有前导空格 —— dpkg 会在这里报 must be followed by colon
        bad.append((i, '既非字段行也非续行（漏前导空格？）', line))
        continue
    seen_field = True

# 必备字段
for field in ('Package', 'Version', 'Architecture', 'Maintainer', 'Description'):
    if not re.search(r'^%s:' % field, text, re.M):
        bad.append((0, '缺少必备字段 %s' % field, ''))

if bad:
    print('!! control 自检未通过（%s）:' % path)
    for ln, why, txt in bad:
        print('   第 %-4s 行: %s' % (ln or '-', why))
        if txt:
            print('              %s' % txt[:90])
    sys.exit(1)

print('OK  control 自检通过（%s，%d 行，%d 字节）' % (path, text.count('\n'), len(raw)))
