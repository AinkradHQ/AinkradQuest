DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR
DEV_PLUGINS := $(HOME)/Library/Application Support/com.ainkrad.devhost/Documents/DevPlugins

generate: ; xcodegen generate
build: generate ; xcodebuild -scheme QuestPlugin -configuration Debug -derivedDataPath build -destination 'platform=macOS' build
sideload: build
	mkdir -p "$(DEV_PLUGINS)"
	rm -rf "$(DEV_PLUGINS)/QuestPlugin.bundle"
	cp -R build/Build/Products/Debug/QuestPlugin.bundle "$(DEV_PLUGINS)/QuestPlugin.bundle"
test: generate ; xcodebuild -scheme QuestPlugin -configuration Debug -derivedDataPath build -destination 'platform=macOS' test
release: ; ./scripts/release.sh $(V)
