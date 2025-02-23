STATIC_LINKING := 0
AR             := ar
ODIN_VERSION   := dev-2025-02
TARGET_NAME    := virtualxt
CORE_DIR       := ../../../
ODIN_UNPACK    := unzip odin.zip

ifneq ($(V),1)
   Q := @
endif

ifeq ($(platform),)
   platform = unix
   ifeq ($(shell uname -s),)
      platform = win
   else ifneq ($(findstring MINGW,$(shell uname -s)),)
      platform = win
   else ifneq ($(findstring Darwin,$(shell uname -s)),)
      platform = osx
   else ifneq ($(findstring win,$(shell uname -s)),)
      platform = win
   endif
endif

# system platform
system_odin = linux-amd64
ifeq ($(shell uname -a),)
	system_odin = windows-amd64
else ifneq ($(findstring Darwin,$(shell uname -a)),)
	system_odin = macos-amd64
	ifeq ($(shell uname -p),arm)
    	system_odin = macos-arm64
	endif
else ifneq ($(findstring MINGW,$(shell uname -a)),)
	system_odin = windows-amd64
endif

OBJ_EXT := o
ifeq ($(STATIC_LINKING), 1)
   EXT := a
else
   ODIN_FLAGS = -reloc-mode:pic
endif

ifneq (,$(findstring unix,$(platform)))
   EXT ?= so
   TARGET := $(TARGET_NAME)_libretro.$(EXT)
   fpic := -fPIC
   SHARED := -shared -Wl,--no-undefined

   # NOTE: We only support linux amd64 atm.
   ODIN_TARGET = linux_amd64
else ifeq ($(platform), linux-portable)
   EXT ?= so
   TARGET := $(TARGET_NAME)_libretro.$(EXT)
   fpic := -fPIC -nostdlib
   SHARED := -shared

   # NOTE: We only support linux amd64 atm.
   ODIN_TARGET = freestanding_amd64_sysv
else ifneq (,$(findstring android,$(platform)))
   TARGET := $(TARGET_NAME)_libretro_android.so
   fpic := -fPIC
   SHARED := -shared -Wl,--no-undefined
   TARGET_TRIPLE := unknown

   ifeq ($(platform), android-arm)
      TARGET_TRIPLE = armv7a-linux-androideabi
      ODIN_TARGET = freestanding_arm32
   else ifeq ($(platform), android-arm64)
      TARGET_TRIPLE = aarch64-linux-android
      ODIN_TARGET = freestanding_arm64
   else ifeq ($(platform), android-x86)
      TARGET_TRIPLE = i686-linux-android
      # Note: There are no freestanding i386 target atm. But I think this should work.
      ODIN_TARGET = linux_i386
   else ifeq ($(platform), android-x86_64)
      TARGET_TRIPLE = x86_64-linux-android
      ODIN_TARGET = freestanding_amd64_sysv
   endif

   CC = $(ANDROID_NDK_LLVM)/bin/$(TARGET_TRIPLE)21-clang
   AR = $(ANDROID_NDK_LLVM)/bin/llvm-ar

else ifneq (,$(findstring osx,$(platform)))
   TARGET := $(TARGET_NAME)_libretro.dylib
   fpic := -fPIC
   SHARED := -dynamiclib
   TARGET_PLATFORM = $(shell uname -p)

   ifeq ($(CROSS_COMPILE),1)
		TARGET_RULE   = -target $(LIBRETRO_APPLE_PLATFORM) -isysroot $(LIBRETRO_APPLE_ISYSROOT)
		LDFLAGS      += $(TARGET_RULE)
		TARGET_PLATFORM = $(LIBRETRO_APPLE_PLATFORM)
   endif

   ODIN_FLAGS += -minimum-os-version:13.0
   ifneq (,$(findstring arm,$(TARGET_PLATFORM)))
		ODIN_TARGET = darwin_arm64
   else
		ODIN_TARGET = darwin_amd64
   endif
else ifneq (,$(findstring ios,$(platform)))
   EXT ?= dylib
   TARGET := $(TARGET_NAME)_libretro_ios.$(EXT)
   fpic := -fPIC
   SHARED := -dynamiclib
   MIN_VERSION := -miphoneos-version-min=5.0
   ODIN_FLAGS += -subtarget:ios

   ifeq ($(platform),$(filter $(platform),ios9 ios-arm64))
      MIN_VERSION = -miphoneos-version-min=8.0
      ODIN_FLAGS += -minimum-os-version:8.0
   else
      ODIN_FLAGS += -minimum-os-version:5.0
   endif
   ifeq ($(IOSSDK),)
      IOSSDK := $(shell xcodebuild -version -sdk iphoneos Path)
   endif

   ifeq ($(platform),ios-arm64)
      SHARED += -arch arm64 $(MIN_VERSION) -isysroot $(IOSSDK)
      CC = cc -arch arm64 $(MIN_VERSION) -isysroot $(IOSSDK)
      ODIN_TARGET = darwin_arm64
   else
      SHARED += -arch armv7 $(MIN_VERSION) -isysroot $(IOSSDK)
      CC = cc -arch armv7 $(MIN_VERSION) -isysroot $(IOSSDK)
      ODIN_TARGET = darwin_arm32
   endif
else ifneq (,$(findstring tvos,$(platform)))
   EXT ?= dylib
   TARGET := $(TARGET_NAME)_libretro_tvos.$(EXT)
   fpic := -fPIC
   SHARED := -dynamiclib
   MIN_VERSION := -mappletvos-version-min=9.0

   ifeq ($(TVOSSDK),)
      TVOSSDK := $(shell xcodebuild -version -sdk appletvos Path)
   endif

   SHARED += -arch arm64 $(MIN_VERSION) -isysroot $(TVOSSDK)
   CC = cc -arch arm64 $(MIN_VERSION) -isysroot $(TVOSSDK)
   ODIN_TARGET = freestanding_arm64
else ifneq (,$(findstring msvc,$(platform)))
   CC = cl.exe
   LDFLAGS += -DLL
   OBJ_EXT = obj
   ODIN_TARGET = windows_amd64
   ODIN_UNPACK = powershell -command "Expand-Archive -Force odin.zip ."

   PATH := $(shell IFS=$$'\n'; cygpath "$(VS100COMNTOOLS)../../VC/bin/amd64"):$(PATH)
   PATH := $(PATH):$(shell IFS=$$'\n'; cygpath "$(VS100COMNTOOLS)../IDE")
   LIB := $(shell IFS=$$'\n'; cygpath "$(VS100COMNTOOLS)../../VC/lib/amd64")

   WindowsSdkDir := $(shell reg query "HKLM\SOFTWARE\Microsoft\Microsoft SDKs\Windows\v7.1A" -v "InstallationFolder" | grep -o '[A-Z]:\\.*')
   WindowsSdkDir ?= $(shell reg query "HKLM\SOFTWARE\Microsoft\Microsoft SDKs\Windows\v7.0A" -v "InstallationFolder" | grep -o '[A-Z]:\\.*')

   WindowsSDKLibDir := $(shell cygpath -w "$(WindowsSdkDir)\Lib\x64")
   export LIB := $(LIB);$(WindowsSDKLibDir)
   
   ifeq ($(STATIC_LINKING), 1)
     TARGET := $(TARGET_NAME)_libretro.lib
   	 AR = lib.exe
   else
     TARGET := $(TARGET_NAME)_libretro.dll
     LDFLAGS += kernel32.lib
     LD = link.exe
   endif
else
   TARGET := $(TARGET_NAME)_libretro.dll
   SHARED := -shared -static-libgcc -s -Wl,--no-undefined
   OBJ_EXT = obj

   ifeq ($(platform), win64)
    	ODIN_TARGET = windows_amd64
   else
		ODIN_TARGET = windows_i386
   endif
endif

MKPATH = $(dir $(realpath $(lastword $(MAKEFILE_LIST))))
OBJECTS = $(TARGET_NAME)_libretro.$(OBJ_EXT)

all: $(TARGET)

setup:
	curl -L -o odin.zip https://github.com/odin-lang/Odin/releases/download/$(ODIN_VERSION)/odin-$(system_odin)-$(ODIN_VERSION).zip && $(ODIN_UNPACK)

$(OBJECTS): setup
	PATH="$(PATH):$(MKPATH)/odin-$(system_odin)-$(ODIN_VERSION)" ODIN_TARGET=$(ODIN_TARGET) ODIN_FLAGS="$(ODIN_FLAGS)" ODIN_VET= $(MAKE) -C $(CORE_DIR) object

$(TARGET): $(OBJECTS)
ifeq ($(STATIC_LINKING), 1)
	ifneq (,$(findstring msvc,$(platform)))
		$(AR) -out:$@ $(OBJECTS)
	else
		$(AR) rcs $@ $(OBJECTS)
	endif
else
	@$(if $(Q), $(shell echo echo LD $@),)
	$(Q)$(CC) $(fpic) $(SHARED) -o $@ $(CORE_DIR)$(OBJECTS) $(LDFLAGS)
endif

clean:
	rm -f $(OBJECTS) $(TARGET) odin.zip
	rm -rf odin-$(system_odin)-$(ODIN_VERSION)
	-$(MAKE) -C $(CORE_DIR) clean

.PHONY: clean

print-%:
	@echo '$*=$($*)'
