# Changelog

## [0.5.0](https://github.com/znat/parrotflow/compare/v0.4.0...v0.5.0) (2026-08-04)


### Features

* a menu of the things you cannot already do with the hotkey ([#18](https://github.com/znat/parrotflow/issues/18)) ([c1ce1a3](https://github.com/znat/parrotflow/commit/c1ce1a3c57a2e08af7e3b885c0fe80e701e26efc))
* a transform can be a program of your own ([#23](https://github.com/znat/parrotflow/issues/23)) ([ff21615](https://github.com/znat/parrotflow/commit/ff21615689cbab25795c5b54a58c9fb951232a1a))
* a transform can say what it is doing while it does it ([#24](https://github.com/znat/parrotflow/issues/24)) ([4fdc1c2](https://github.com/znat/parrotflow/commit/4fdc1c24c50541879d87d9c58d40c8a447fdf472))
* keep what the decoder knew, not just what it said ([#37](https://github.com/znat/parrotflow/issues/37)) ([5821568](https://github.com/znat/parrotflow/commit/5821568e5334cc436322d28cbfa22d5419ca2696))
* let a correction be asked for inside a dictation ([#19](https://github.com/znat/parrotflow/issues/19)) ([929192a](https://github.com/znat/parrotflow/commit/929192a1bd28d7482f6ceae3182fd1282840098b))
* say "undo" and the last substitution goes back ([#39](https://github.com/znat/parrotflow/issues/39)) ([8ab4f88](https://github.com/znat/parrotflow/commit/8ab4f884a756fdc5147ddb01056ae041198f171e))
* the app has a face, and the menu bar a bird that follows the light ([#36](https://github.com/znat/parrotflow/issues/36)) ([cb7797a](https://github.com/znat/parrotflow/commit/cb7797adca3abe36f9fa298eb6f2c230b8fc1a46))
* the menu says which microphone the next press will use ([#34](https://github.com/znat/parrotflow/issues/34)) ([c2880f5](https://github.com/znat/parrotflow/commit/c2880f5923da74e596ac9190f1ec74669f90dd5c))
* the mic stays open a moment after you let go ([#25](https://github.com/znat/parrotflow/issues/25)) ([cab9fb5](https://github.com/znat/parrotflow/commit/cab9fb584037e079141786eab98c777c970276ff))
* the pill shows which app it is about to write into ([#27](https://github.com/znat/parrotflow/issues/27)) ([#29](https://github.com/znat/parrotflow/issues/29)) ([b01f6f7](https://github.com/znat/parrotflow/commit/b01f6f7053337cdb045089ebb02eadd79c745ae4))
* the words go to the clipboard when there is nowhere to type them ([#31](https://github.com/znat/parrotflow/issues/31)) ([9079fd3](https://github.com/znat/parrotflow/commit/9079fd3956e0507c761c7a679e8d91005bcd5428))
* two corrections in one breath, or describe the change instead of spelling it ([#21](https://github.com/znat/parrotflow/issues/21)) ([5df2534](https://github.com/znat/parrotflow/commit/5df253437d4f5181368fc48ab495db2ae8c872af))
* writing prompts, and a permissions walk that explains itself ([#30](https://github.com/znat/parrotflow/issues/30)) ([aa136e4](https://github.com/znat/parrotflow/commit/aa136e4c4ef0f62b7b398a89187c136ca8ef0430))


### Fixes

* a dictation that is still working says so on screen ([#35](https://github.com/znat/parrotflow/issues/35)) ([83534be](https://github.com/znat/parrotflow/commit/83534bea5dddc3addcc2c6d297963f5695bb8672))
* a substitution replaces the words instead of landing after them ([#38](https://github.com/znat/parrotflow/issues/38)) ([1e0f5f3](https://github.com/znat/parrotflow/commit/1e0f5f32d0a9e63cb0f2735e15a9450ce18df778))
* an email ends where the speaker stopped, never on a name they did not say ([#33](https://github.com/znat/parrotflow/issues/33)) ([c21283e](https://github.com/znat/parrotflow/commit/c21283eac9b2216d83fc94bb24a1fb6838e9ca30))
* dictations that lose their ending, and a microphone that takes the hotkey with it ([#32](https://github.com/znat/parrotflow/issues/32)) ([13be319](https://github.com/znat/parrotflow/commit/13be319071c3fa7e9fb73706daec167588636919))
* stop a sentence about a parrot from being taken as a command ([#22](https://github.com/znat/parrotflow/issues/22)) ([c2168b3](https://github.com/znat/parrotflow/commit/c2168b3c72cb0bb697605655bd1640d8d09169a2))
* the span harness stops racing its own fixture ([#40](https://github.com/znat/parrotflow/issues/40)) ([ed93043](https://github.com/znat/parrotflow/commit/ed93043a6009b6eec8f3bdedd33e40789279ebe9))

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
