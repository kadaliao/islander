APP := build/Build/Products/Debug/Islander.app

.PHONY: gen build run stop clean release icon

gen:
	xcodegen generate --quiet

build: gen
	xcodebuild -project Islander.xcodeproj -scheme Islander -configuration Debug \
		-destination 'platform=macOS,arch=arm64' -derivedDataPath build -quiet build

run: build stop
	open $(APP)

stop:
	-@pkill -x Islander || true

clean:
	rm -rf build Islander.xcodeproj

# 签名、公证、打包到 build/release/（要联网）
release:
	NOTARY_PROFILE=$${NOTARY_PROFILE:-notary} scripts/release.sh

# 重新生成 App 图标（Islander/App/AppIcon.icon）
icon:
	python3 scripts/make-icon.py
