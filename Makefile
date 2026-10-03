DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR
# The sideload directory is `<cacheRoot>/DevPlugins`, and cacheRoot is
# `~/Library/Application Support/<bundle-id>/Cache` (AinkradHome.defaultCacheRoot).
# Deliberately NOT under the user's Ainkrad Home: dev plugin bundles are
# rebuildable machine state, not vault data.
DEV_PLUGINS := $(HOME)/Library/Application Support/com.ainkrad.app/Cache/DevPlugins

.PHONY: generate build sideload test release
generate: ; xcodegen generate
build: lint generate ; xcodebuild -scheme QuestPlugin -configuration Debug -derivedDataPath build -destination 'platform=macOS' build
sideload: build
	mkdir -p "$(DEV_PLUGINS)"
	rm -rf "$(DEV_PLUGINS)/QuestPlugin.bundle"
	cp -R build/Build/Products/Debug/QuestPlugin.bundle "$(DEV_PLUGINS)/QuestPlugin.bundle"
test: lint generate ; xcodebuild -scheme QuestPlugin -configuration Debug -derivedDataPath build -destination 'platform=macOS' test
release: ; ./scripts/release.sh $(V)

include scripts/guardrails.mk
