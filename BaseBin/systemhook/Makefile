TARGET = systemhook.dylib
CC = clang

CFLAGS = -I../.include -I./src -I../_external/modules/litehook/src -isysroot $(shell xcrun --sdk iphoneos --show-sdk-path) -arch arm64 -arch arm64e -miphoneos-version-min=15.0 -install_name $(TARGET) -Wno-deprecated-declarations -Os -moutline
LDFLAGS = -dynamiclib
INLINE_SVC_OBJS = .inline_svc.o
INLINE_SVC_ARCH_OBJS = .inline_svc.arm64.o .inline_svc.arm64e.o

sign: $(TARGET)
	@ldid -S $^

$(TARGET): $(wildcard src/main.c src/roothider_common.c src/roothider_main.c src/common/*.c src/common/*.S ../libjailbreak/src/jbclient_*.c ../libjailbreak/src/hookd.c ../libjailbreak/src/inline_svc.c ../_external/modules/litehook/src/*.c ../libjailbreak/src/roothider/jailbreakd.c) $(INLINE_SVC_OBJS)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $(filter-out $(INLINE_SVC_OBJS),$^) $(INLINE_SVC_OBJS)

.inline_svc.o: $(INLINE_SVC_ARCH_OBJS)
	lipo -create $^ -output $@

.inline_svc.arm64.o: ../libjailbreak/src/inline_svc.S
	$(CC) $(filter-out -arch arm64 -arch arm64e,$(CFLAGS)) -arch arm64 -c $< -o $@

.inline_svc.arm64e.o: ../libjailbreak/src/inline_svc.S
	$(CC) $(filter-out -arch arm64 -arch arm64e,$(CFLAGS)) -arch arm64e -c $< -o $@

clean:
	@rm -f $(TARGET) $(INLINE_SVC_OBJS) $(INLINE_SVC_ARCH_OBJS)
