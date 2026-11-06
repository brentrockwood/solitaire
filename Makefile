# Build the Solitaire.app bundle from the Swift package.
#   make app        release build + bundle in build/Solitaire.app
#   make run        build and launch
#   make test       unit tests (needs Xcode's license accepted)
#   make install    copy to /Applications

APP      := build/Solitaire.app
BIN      := .build/release/Solitaire
ICONSET  := build/AppIcon.iconset
SWIFT    := swift

.PHONY: app run test install clean

$(BIN): $(wildcard Sources/*/*.swift) Package.swift
	$(SWIFT) build -c release 2>&1 | grep -v 'warning: search path' ; test -x $(BIN)

app: $(BIN) Resources/Info.plist
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(BIN) $(APP)/Contents/MacOS/Solitaire
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	rm -rf $(ICONSET); $(BIN) --render-icon $(ICONSET) && iconutil -c icns -o $(APP)/Contents/Resources/AppIcon.icns $(ICONSET)
	codesign --force --sign - $(APP) 2>/dev/null || true
	@echo "Built $(APP)"

run: app
	open $(APP)

test:
	$(SWIFT) test 2>&1 | grep -E 'Test run|passed|failed|error' 

install: app
	rm -rf /Applications/Solitaire.app && cp -R $(APP) /Applications/Solitaire.app

clean:
	rm -rf .build build
