.PHONY: generate build run test install clean

APP = build/DerivedData/Build/Products/Release/Anki Learn.app

# XcodeGen 生成工程（brew install xcodegen）；工程文件不进 git
generate:
	xcodegen generate

build: generate
	xcodebuild -quiet -project AnkiLearn.xcodeproj -scheme AnkiLearn -configuration Release \
	  -derivedDataPath build/DerivedData build

run: build
	open "$(APP)"

# 核心库的测试：读会话、切段、出卡解析、DeepSeek 和 AnkiConnect 请求（假服务器）
test:
	cd Core && swift test

# 装到 /Applications（自用）
install: build
	osascript -e 'quit app "Anki Learn"' 2>/dev/null || true
	rm -rf "/Applications/Anki Learn.app"
	cp -R "$(APP)" /Applications/
	@echo "装好了：/Applications/Anki Learn.app"

clean:
	rm -rf AnkiLearn.xcodeproj build
