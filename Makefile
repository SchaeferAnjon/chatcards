.PHONY: generate build run test install clean

APP = build/DerivedData/Build/Products/Release/ChatCards.app

# 签名：默认临时签名（ad-hoc）。给了 TEAM 就用这个 Team 的 Apple Development 证书签，
# 重新编译后钥匙串里的 Key 照样能读。TEAM 可以写在 local.mk 里（不进 git）：TEAM = <Team ID>
-include local.mk
SIGN = $(if $(TEAM),DEVELOPMENT_TEAM=$(TEAM) CODE_SIGN_IDENTITY="Apple Development",)

# XcodeGen 生成工程（brew install xcodegen）；工程文件不进 git
generate:
	xcodegen generate

build: generate
	xcodebuild -quiet -project ChatCards.xcodeproj -scheme ChatCards -configuration Release \
	  -derivedDataPath build/DerivedData $(SIGN) build

run: build
	open "$(APP)"

# 核心库的测试：读会话、切段、出卡解析、DeepSeek 和 AnkiConnect 请求（假服务器）
test:
	cd Core && swift test

# 装到 /Applications
install: build
	osascript -e 'quit app "ChatCards"' 2>/dev/null || true
	rm -rf "/Applications/ChatCards.app"
	cp -R "$(APP)" /Applications/
	@echo "装好了：/Applications/ChatCards.app"

clean:
	rm -rf ChatCards.xcodeproj build
