# Changelog

## [0.4.0](https://github.com/znat/parrotflow/compare/v0.3.0...v0.4.0) (2026-08-02)


### Features

* capture groups, named transforms, and dotted paths by app ([#9](https://github.com/znat/parrotflow/issues/9)) ([f744c01](https://github.com/znat/parrotflow/commit/f744c01bce2cc404569c7fab9dd5d82e18386624))
* gate a pipeline stage by the app you dictated into ([#5](https://github.com/znat/parrotflow/issues/5)) ([852afa5](https://github.com/znat/parrotflow/commit/852afa52551dd089a16a946f91426bc9db5a14b9))
* install an update from inside the app ([#15](https://github.com/znat/parrotflow/issues/15)) ([#17](https://github.com/znat/parrotflow/issues/17)) ([411dfda](https://github.com/znat/parrotflow/commit/411dfda2f8044f298717cdafd55e32854644b67f))
* notice when a newer version exists, after it has aged ([#14](https://github.com/znat/parrotflow/issues/14)) ([8056802](https://github.com/znat/parrotflow/commit/8056802a10ad6d725465986248bc2dd3127f4f47))
* several activation phrases, and one said inside a dictation ([#16](https://github.com/znat/parrotflow/issues/16)) ([1e105cd](https://github.com/znat/parrotflow/commit/1e105cd7f4e278a2b8d884c9fbc48d0c0a4ff8f8))


### Fixes

* refuse an app that was signed by someone else ([#10](https://github.com/znat/parrotflow/issues/10)) ([896fae9](https://github.com/znat/parrotflow/commit/896fae909ed5366b9edd1973f7e0bb06698e2b7f))
* say in the app when a setting has stopped doing anything ([#11](https://github.com/znat/parrotflow/issues/11)) ([c95117c](https://github.com/znat/parrotflow/commit/c95117c003dfcd368ad8529c0c09685c15d165b4))


### Performance

* draw the menu bar icon when it changes, not ten times a second ([#12](https://github.com/znat/parrotflow/issues/12)) ([8de3492](https://github.com/znat/parrotflow/commit/8de349281da9248f03ffa6ebe6cccda83275d430))

## [0.3.0](https://github.com/znat/parrotflow/compare/v0.2.0...v0.3.0) (2026-08-02)


### Features

* configure the transcript pipeline per language, instead of flags ([#7](https://github.com/znat/parrotflow/issues/7)) ([e9e038b](https://github.com/znat/parrotflow/commit/e9e038b0bac7218ad548c1468976aeae7803d247))

## [0.2.0](https://github.com/znat/parrotflow/compare/v0.1.0...v0.2.0) (2026-08-01)


### Features

* do what was asked when no prompt matches ([f79f667](https://github.com/znat/parrotflow/commit/f79f667f365a57cb6aadd0f882175aead83db240))
* give the floating surfaces one look, and a way to look at them ([12f6ece](https://github.com/znat/parrotflow/commit/12f6ecee10e60aa8571447eb1dda1104e4449f58))
* read dates and clock times without a model, behind --dates ([b12b629](https://github.com/znat/parrotflow/commit/b12b629a7a730952953fea53e59b29319bb9ac42))
* read spoken numbers in French, and in Belgian and Swiss French ([311e34b](https://github.com/znat/parrotflow/commit/311e34b951e7c4a43355100a840d4ff637d932e7))


### Fixes

* stop release-certificate.sh dying before it prints anything ([d7f11e0](https://github.com/znat/parrotflow/commit/d7f11e0b9bc7e3452ff142de03c8a385133868b4))


### Performance

* keep the pinned model warm, and shorten the English spelling prompt ([bfd79f2](https://github.com/znat/parrotflow/commit/bfd79f23b61fb9f3ab7c6f0f27e78d51a9ac9e3e))
