SCHEME      = Cropmark
DERIVED     = $(HOME)/Library/Caches/CropmarkBuild
APP         = $(DERIVED)/Build/Products/Debug/Cropmark.app
XCB         = xcodebuild -project Cropmark.xcodeproj -scheme $(SCHEME) -derivedDataPath $(DERIVED) -destination 'platform=macOS' CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES
# 构建用 ad-hoc，装机前用本机的 Apple Development 证书重签，这样重编译后「屏幕录制」权限不会失效
SIGN_ID    ?= $(shell security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development|Developer ID Application/ {print $$2; exit}')

.PHONY: gen build sign run stop test install clean icon

$(DERIVED):
	mkdir -p $(DERIVED)

gen:
	xcodegen generate

# 重新生成应用图标（Cropmark/Resources/AppIcon.icns）
icon: $(DERIVED)
	swift scripts/make-icon.swift $(DERIVED)
	cp $(DERIVED)/AppIcon.icns Cropmark/Resources/AppIcon.icns

build: gen $(DERIVED)
	$(XCB) -configuration Debug build 2>&1 | tee $(DERIVED)/build.log | grep -E "error:|warning: unre|BUILD (SUCCEEDED|FAILED)" || true

sign: build
	@if [ -n "$(SIGN_ID)" ]; then codesign --force --deep --sign $(SIGN_ID) $(APP) && echo "signed with $(SIGN_ID)"; else echo "no Apple Development identity, keeping ad-hoc signature"; fi

run: sign stop
	open $(APP)

stop:
	-pkill -x Cropmark 2>/dev/null || true

test: gen $(DERIVED)
	$(XCB) test 2>&1 | tee $(DERIVED)/test.log | grep -E "error:|Test Case.*(passed|failed)|Executed|BUILD|TEST" || true

install: sign stop
	rm -rf /Applications/Cropmark.app
	cp -R $(APP) /Applications/Cropmark.app
	open /Applications/Cropmark.app

clean:
	rm -rf $(DERIVED) Cropmark.xcodeproj
