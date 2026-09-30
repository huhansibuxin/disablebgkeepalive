TARGET := iphone:clang:latest:16.0
ARCHS := arm64 arm64e
# scheme 由 CI 环境变量决定（rootless 默认，roothide 构建时 CI 传 roothide）；
# 必须用 ?= 条件赋值——普通赋值会覆盖环境变量，roothide job 会被打回 rootless。
THEOS_PACKAGE_SCHEME ?= rootless
export THEOS_PACKAGE_SCHEME

# 性能/符号：三变量一起给（只写 OPTFLAG 无效，会被 -O0 压掉）
#   DEBUG=0   -> 不进 DEBUG schema，{-DDEBUG -O0} 不再追加到 CFLAGS 末尾
#   STRIP=0   -> 保留符号，崩溃栈仍可符号化
#   OPTFLAG   -> 覆盖默认 -O0
DEBUG = 0
STRIP = 0
OPTFLAG = -O2

export _THEOS_PLATFORM_DPKG_DEB_COMPRESSION = gzip

TWEAK_NAME := SwiftgramNoBgCPU

SwiftgramNoBgCPU_FILES := Tweak.xm
SwiftgramNoBgCPU_CFLAGS := -fobjc-arc -w
SwiftgramNoBgCPU_FRAMEWORKS := UIKit Foundation

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
