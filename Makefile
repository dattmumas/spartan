CONFIG ?= release

.PHONY: build app run check cert clean

build:
	swift build -c $(CONFIG)

app: build
	scripts/make-app.sh $(CONFIG)

run: app
	open dist/Spartan.app

check:
	swift build -c debug --product SpartanChecks
	.build/debug/SpartanChecks

cert:
	scripts/make-cert.sh

clean:
	rm -rf .build dist
