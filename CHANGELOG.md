# Changelog

## [0.12.0](https://github.com/znat/parrotflow/compare/v0.11.0...v0.12.0) (2026-09-05)


### ⚠ BREAKING CHANGES

* the vocabulary stage decides without a model ([#246](https://github.com/znat/parrotflow/issues/246))

### Features

* a correction the other way is a counter-example ([#251](https://github.com/znat/parrotflow/issues/251)) ([57d9fa0](https://github.com/znat/parrotflow/commit/57d9fa06f9675d8ee3be4cad1bed41d7db4a70a6))
* a name corrected by hand opens the vocabulary panel ([#248](https://github.com/znat/parrotflow/issues/248)) ([1256bb8](https://github.com/znat/parrotflow/commit/1256bb80a20666eae5a4afd99c603baebd22f1a6))
* a name is found by how it sounds, and the free gate decides the easy ones ([#234](https://github.com/znat/parrotflow/issues/234)) ([673ea9e](https://github.com/znat/parrotflow/commit/673ea9e81375b311ab2327545aaa031df4c09d8e))
* a name is only written where the sentence says it belongs ([#245](https://github.com/znat/parrotflow/issues/245)) ([7398a15](https://github.com/znat/parrotflow/commit/7398a15b901291dfa4190d5c7aad363c481234dd))
* a pause no longer cuts a sentence in two ([#230](https://github.com/znat/parrotflow/issues/230)) ([6574676](https://github.com/znat/parrotflow/commit/6574676700da1dd9b4392d64193f97d5c4988265))
* a priority list of microphones, set from the menu bar ([#284](https://github.com/znat/parrotflow/issues/284)) ([e3b148d](https://github.com/znat/parrotflow/commit/e3b148dff194eb21a76aa3a9a52a0f643b9a5d40))
* a term is refused where it looks more like its counter-examples ([#252](https://github.com/znat/parrotflow/issues/252)) ([d0ccccf](https://github.com/znat/parrotflow/commit/d0ccccfb02dd652ed391027fe2197d6ff271ecce))
* a term learns where it belongs from its own corrections ([#244](https://github.com/znat/parrotflow/issues/244)) ([5fce520](https://github.com/znat/parrotflow/commit/5fce520bac19bff0d0962f58d5bebfcacb6cabd1))
* a term's portrait starts from its first use and its first counter-example ([#282](https://github.com/znat/parrotflow/issues/282)) ([d2e1534](https://github.com/znat/parrotflow/commit/d2e15347d45bea9bf15207509f250c23fece0634))
* hand edits are kept, and the popup opens only on names ([#259](https://github.com/znat/parrotflow/issues/259)) ([9582266](https://github.com/znat/parrotflow/commit/9582266e78a1d1bfc8a0c3792b29e3233e358017))
* notice when one word of a dictation is changed by hand ([#247](https://github.com/znat/parrotflow/issues/247)) ([c8ae4c7](https://github.com/znat/parrotflow/commit/c8ae4c73f6ce6aa02ee29aa01dbd619ef8c5f3ba))
* readings repair false sentence breaks, and the vocabulary gate reads French ([#281](https://github.com/znat/parrotflow/issues/281)) ([73b4a36](https://github.com/znat/parrotflow/commit/73b4a369fb1b5e1a1e55121591510e422fa008da))
* tap the hotkey to edit what you just said, or what you have selected ([#220](https://github.com/znat/parrotflow/issues/220)) ([704589d](https://github.com/znat/parrotflow/commit/704589df3499e5510917932fdcb222affbd12081))
* the dictation HUD hangs off the words it is about ([#224](https://github.com/znat/parrotflow/issues/224)) ([03956bd](https://github.com/znat/parrotflow/commit/03956bdf441c8708392c483b2d33a392c3378720))
* the sentence decides whether a name can go where a word stands ([#229](https://github.com/znat/parrotflow/issues/229)) ([a0c1f2f](https://github.com/znat/parrotflow/commit/a0c1f2f5a7195363cdd5cb93dd323dfa64efb735))
* the sentence model arrives on the first English dictation ([#225](https://github.com/znat/parrotflow/issues/225)) ([d3efed8](https://github.com/znat/parrotflow/commit/d3efed8218930a123f58756b9e7b7bc3bf4f59c0))
* the sentence model says whether a period is real ([#227](https://github.com/znat/parrotflow/issues/227)) ([76ab662](https://github.com/znat/parrotflow/commit/76ab662a3bdf8490970e13da6f5fe3ade2b1bbd0))
* the slot says whether a name belongs where it was heard ([#243](https://github.com/znat/parrotflow/issues/243)) ([49f8696](https://github.com/znat/parrotflow/commit/49f8696abcf71bfe7826244d280e1f477f554303))
* the start chime waits until the microphone is sending ([483bed8](https://github.com/znat/parrotflow/commit/483bed81f26470158ead6968008be6f9b09d2cad))
* the vocabulary stage decides without a model ([#246](https://github.com/znat/parrotflow/issues/246)) ([1852471](https://github.com/znat/parrotflow/commit/1852471781aba8f9f90bd6ff679cd378ae037971))
* two ears for one name, and the one that needs no install is the default ([#235](https://github.com/znat/parrotflow/issues/235)) ([161fc20](https://github.com/znat/parrotflow/commit/161fc206c9541204ed07c2694052875fc122db16))


### Fixes

* `review: false` stops the model and nothing else ([#237](https://github.com/znat/parrotflow/issues/237)) ([8510797](https://github.com/znat/parrotflow/commit/8510797738ea6acd8c558d6e71241088bce0f392))
* a capital at the start of a sentence is not a name ([#253](https://github.com/znat/parrotflow/issues/253)) ([b49df60](https://github.com/znat/parrotflow/commit/b49df60bff7e65e87de394084df58a126f39616c))
* a contraction is not a name to overwrite ([#233](https://github.com/znat/parrotflow/issues/233)) ([954513d](https://github.com/znat/parrotflow/commit/954513dcbea33bd87040c895cddfd24a15890d94))
* a correction rebuilds the term's portrait, not the next dictation ([#257](https://github.com/znat/parrotflow/issues/257)) ([eb7088f](https://github.com/znat/parrotflow/commit/eb7088f2c4ccb1e3aab0f50966958cc734e0c022))
* a dictation no longer ends with words nobody said ([#272](https://github.com/znat/parrotflow/issues/272)) ([68774e0](https://github.com/znat/parrotflow/commit/68774e015f0cd8af2cb4a5f7fdccf31a50eafa79))
* a word added beside another is not a correction of it ([#254](https://github.com/znat/parrotflow/issues/254)) ([53a8739](https://github.com/znat/parrotflow/commit/53a87391b1721b11956996895617f7164cf590f4))
* a word with a possessive is no longer overwritten without asking ([#223](https://github.com/znat/parrotflow/issues/223)) ([e68b1d8](https://github.com/znat/parrotflow/commit/e68b1d8a7f4c38f691c644c654226080f0c898cb))
* an ordinary first name is no longer overwritten without asking ([#222](https://github.com/znat/parrotflow/issues/222)) ([adf529f](https://github.com/znat/parrotflow/commit/adf529f44577f8407f87c2d0dadbef348d5d6ecb))
* **pill:** open where the words are, not at the bottom of the screen ([#217](https://github.com/znat/parrotflow/issues/217)) ([f0eebee](https://github.com/znat/parrotflow/commit/f0eebee8644407ec4365ff570760b11c042db3e1))
* the in-place check no longer leaks or kills windows it didn't open ([#221](https://github.com/znat/parrotflow/issues/221)) ([3ab201f](https://github.com/znat/parrotflow/commit/3ab201f5c8f7831cecb38cc02ea1d7399e3a6e08))
* the rank rule goes, it was wrong more often than right ([#241](https://github.com/znat/parrotflow/issues/241)) ([955c072](https://github.com/znat/parrotflow/commit/955c072045313d37942ccb3d52f2e60b26a6dada))


### Performance

* speech downloads first, the other three follow ([#250](https://github.com/znat/parrotflow/issues/250)) ([64b0890](https://github.com/znat/parrotflow/commit/64b0890a21adcbd1d7954e3a543897e543c030a5))
* the sound model's answers are kept between launches ([#255](https://github.com/znat/parrotflow/issues/255)) ([ed542d1](https://github.com/znat/parrotflow/commit/ed542d122c4c11f7fd765a0bc79a4ab2a6918fee))
* the tokenizer is parsed once per process ([#228](https://github.com/znat/parrotflow/issues/228)) ([87d2f9d](https://github.com/znat/parrotflow/commit/87d2f9d128b64275ff90ec420f95e554f1c9fbd5))

## [0.11.0](https://github.com/znat/parrotflow/compare/v0.10.0...v0.11.0) (2026-08-26)


### Features

* the pill shows the speech model downloading, with the percentage ([#206](https://github.com/znat/parrotflow/issues/206)) ([877090e](https://github.com/znat/parrotflow/commit/877090e409ea239dbdd78a141208d624ca6ea929))


### Fixes

* the pill no longer goes blank while a second dictation is running ([#210](https://github.com/znat/parrotflow/issues/210)) ([f89fea8](https://github.com/znat/parrotflow/commit/f89fea8acb371b3c908e05bd76379be6d9afdb79)), closes [#209](https://github.com/znat/parrotflow/issues/209)


### Performance

* the pill arrives when the microphone opens, not 180 ms later ([#207](https://github.com/znat/parrotflow/issues/207)) ([6184786](https://github.com/znat/parrotflow/commit/6184786625f586b66ae6e26d42c3b2900b3a6249))

## [0.10.0](https://github.com/znat/parrotflow/compare/v0.9.0...v0.10.0) (2026-08-26)


### ⚠ BREAKING CHANGES

* the signing identity changes, so everyone on v0.9.0 or earlier grants Microphone and Accessibility once more. The updater in those builds refuses the first notarized release rather than swapping the identity and leaving the app with no microphone. Those users re-run the install line or install with brew.
* one pipeline, and pipelines: is refused ([#202](https://github.com/znat/parrotflow/issues/202))

### Features

* a dictation keeps its bullets, bold and links when the app takes them ([#196](https://github.com/znat/parrotflow/issues/196)) ([bffbc87](https://github.com/znat/parrotflow/commit/bffbc879c2cc3e1cee2014c671968b0e159b99a0))
* one pipeline, and pipelines: is refused ([#202](https://github.com/znat/parrotflow/issues/202)) ([5b03475](https://github.com/znat/parrotflow/commit/5b03475f47fee98a9cc9275faa293c777fb7e7ae))
* releases are notarized, and there is a Homebrew cask ([#205](https://github.com/znat/parrotflow/issues/205)) ([763fffb](https://github.com/znat/parrotflow/commit/763fffbc5382c41b3addcd79c3d0405ff5fe024b))
* report a bug from the menu, with the config and the log already in it ([#193](https://github.com/znat/parrotflow/issues/193)) ([1f970b7](https://github.com/znat/parrotflow/commit/1f970b798c556a5228661bdf0c05e22de32fedac))
* say "PR one two three" and get a link you can click ([#201](https://github.com/znat/parrotflow/issues/201)) ([006acac](https://github.com/znat/parrotflow/commit/006acac0da7c938b2cc24976bdd017e7db5ad04a))
* the pill is smaller and its chimes are quieter ([#203](https://github.com/znat/parrotflow/issues/203)) ([e233609](https://github.com/znat/parrotflow/commit/e2336093da537a2dda3c927205c4063c85359d82))


### Fixes

* a bare-modifier hotkey ignores a press that belongs to a shortcut ([#194](https://github.com/znat/parrotflow/issues/194)) ([040de86](https://github.com/znat/parrotflow/commit/040de86512a07d09f724d0d19cb07d4869d2e15a))


### Performance

* the hidden pill stops redrawing, the settle loop stops re-folding ([#190](https://github.com/znat/parrotflow/issues/190)) ([363cc79](https://github.com/znat/parrotflow/commit/363cc795d701cdaf60eca59eb59a073d23f06ea7))

## [0.9.0](https://github.com/znat/parrotflow/compare/v0.8.0...v0.9.0) (2026-08-20)


### Features

* a self-correction prompt tuned against real dictation ([#178](https://github.com/znat/parrotflow/issues/178)) ([012ff7d](https://github.com/znat/parrotflow/commit/012ff7d4f976eb92eb47ee2b78629a54a6ac569e))


### Fixes

* an offered rewrite lands in the field, or on the clipboard ([#171](https://github.com/znat/parrotflow/issues/171)) ([bfdd747](https://github.com/znat/parrotflow/commit/bfdd7471d7200072e6db0e32a95e4a1751a87c67))
* say on screen when an offered transform changes nothing ([#176](https://github.com/znat/parrotflow/issues/176)) ([558f04e](https://github.com/znat/parrotflow/commit/558f04e9899709c9d65d1e32d7735c542f71fa53))
* the caret walk checks the characters, not the numbers naming them ([#173](https://github.com/znat/parrotflow/issues/173)) ([3ac8147](https://github.com/znat/parrotflow/commit/3ac8147b4e783a5c6c32bad2ca21048a5811ca52))
* the offer opens to its full width, with every chip inside the pill ([#179](https://github.com/znat/parrotflow/issues/179)) ([3a8a849](https://github.com/znat/parrotflow/commit/3a8a849105719972673aac752c56f369864ff308))

## [0.8.0](https://github.com/znat/parrotflow/compare/v0.7.0...v0.8.0) (2026-08-20)


### ⚠ BREAKING CHANGES

* every model in one place, and names are one stage ([#156](https://github.com/znat/parrotflow/issues/156))

### Features

* a command path may share a script under transforms/, and examples install as one tree ([#157](https://github.com/znat/parrotflow/issues/157)) ([01c03d2](https://github.com/znat/parrotflow/commit/01c03d2fa87f5c99d5e3dd8e8bf774390e9f73ed))
* a second decode, run beside the first, gets the skipped words back ([#163](https://github.com/znat/parrotflow/issues/163)) ([6606a32](https://github.com/znat/parrotflow/commit/6606a320d0e8f00f8e91bd2c7d078825b0271a26))
* ask for a missing or rejected API key when the model is used ([#166](https://github.com/znat/parrotflow/issues/166)) ([2b67ead](https://github.com/znat/parrotflow/commit/2b67eadef9b4b7b453d962e06fe59bfb124f9f73))
* **config:** name models, pick one per prompt, and keep the key in the keychain ([#153](https://github.com/znat/parrotflow/issues/153)) ([02862c3](https://github.com/znat/parrotflow/commit/02862c3ccf7430597011ef55538247e98f825ffa))
* every model in one place, and names are one stage ([#156](https://github.com/znat/parrotflow/issues/156)) ([82fd06f](https://github.com/znat/parrotflow/commit/82fd06fe9265d605a29f981faacfa287cab375ab))
* the log shows the caret and the text either side of it ([#159](https://github.com/znat/parrotflow/issues/159)) ([60b99c3](https://github.com/znat/parrotflow/commit/60b99c32e1c0eee305694e19707e10a1a024dd4b))
* the offer holds at full strength before it fades, and its keys shimmer ([#162](https://github.com/znat/parrotflow/issues/162)) ([e352e69](https://github.com/znat/parrotflow/commit/e352e6968871f7d799589a713c626be8544f3908))
* the repetitions transform brings its own scorer ([#160](https://github.com/znat/parrotflow/issues/160)) ([ae7f080](https://github.com/znat/parrotflow/commit/ae7f0803aeb5b852f0fe334ada7544f4956781fa))
* the update offer draws its notes, and a dev build stops trying to install one ([#155](https://github.com/znat/parrotflow/issues/155)) ([869049a](https://github.com/znat/parrotflow/commit/869049afbd673b3cf995d114e4760d06d83ab95d))
* vocabulary judge — annotate {terms} with each term's kind ([#167](https://github.com/znat/parrotflow/issues/167)) ([81df169](https://github.com/znat/parrotflow/commit/81df169ef05e58d0f726b3d7fa7ba0b6d7f7e42c))


### Fixes

* a dictation the decoder returned nothing for is decoded again ([#158](https://github.com/znat/parrotflow/issues/158)) ([0edf9fc](https://github.com/znat/parrotflow/commit/0edf9fc62d308c37044bf9f342bb459b6a6d6a97))
* the prune reports what it did, not what it meant to do ([#161](https://github.com/znat/parrotflow/issues/161)) ([bc7ec35](https://github.com/znat/parrotflow/commit/bc7ec35dd727744e1251340cc1b77d0fdbb7be59))

## [0.7.0](https://github.com/znat/parrotflow/compare/v0.6.0...v0.7.0) (2026-08-19)


### Features

* a spelling lesson keeps the word it is teaching ([#143](https://github.com/znat/parrotflow/issues/143)) ([7e19a7e](https://github.com/znat/parrotflow/commit/7e19a7e74d6e56c153912b3f53890b2501854d49))
* a table says what it wrote, and join fits a clip to the box ([#148](https://github.com/znat/parrotflow/issues/148)) ([461ea43](https://github.com/znat/parrotflow/commit/461ea4332725a905f294cfb358b0657b8268fed8))
* code_identifiers publishes the identifiers it wrote ([#146](https://github.com/znat/parrotflow/issues/146)) ([649b08c](https://github.com/znat/parrotflow/commit/649b08c7962f405f72aeaec25c9bf96e514cb8d6))
* name the word lists once, and let dotted hear dash and slash ([#149](https://github.com/znat/parrotflow/issues/149)) ([aadf036](https://github.com/znat/parrotflow/commit/aadf036a1bc8451132159a9566313caabc391f64))
* play Morse instead of Glass for the completion chime ([#139](https://github.com/znat/parrotflow/issues/139)) ([982bc07](https://github.com/znat/parrotflow/commit/982bc071ebdddd60d7be284930f63028390a1ea3))
* punctuation gains brackets, semicolon, ellipsis and French ([#150](https://github.com/znat/parrotflow/issues/150)) ([dbf028c](https://github.com/znat/parrotflow/commit/dbf028c951d88f914f4cd910af668848b7526e6b))
* read the input box, tag the words, and hand a transform the whole run ([#147](https://github.com/znat/parrotflow/issues/147)) ([f079683](https://github.com/znat/parrotflow/commit/f0796833ac8569b2d31350a4fc9bf4db28e3bafb))
* surface update alert automatically, check hourly, and drop Correct a Word from menu ([#142](https://github.com/znat/parrotflow/issues/142)) ([5cc602b](https://github.com/znat/parrotflow/commit/5cc602bb7ffa82d89c4d6838f7506a19834c4518))
* the offer says when the words may not be your words ([#151](https://github.com/znat/parrotflow/issues/151)) ([e9c8578](https://github.com/znat/parrotflow/commit/e9c857869ef38665f7479cec27a6233f18d080ae))
* the vocabulary panel is a table again, with the rows proposed ([#152](https://github.com/znat/parrotflow/issues/152)) ([e5ea7c4](https://github.com/znat/parrotflow/commit/e5ea7c42f721d4d774c82972b6b6f30dccf384c8))


### Fixes

* a repeat holding "I" is no longer kept as a spelled letter ([#145](https://github.com/znat/parrotflow/issues/145)) ([0dc8153](https://github.com/znat/parrotflow/commit/0dc81535c04b2e55856ac5dfff51259b6db36e1b))
* get past the version-manager shim, and stop trimming what a stage added ([#144](https://github.com/znat/parrotflow/issues/144)) ([a0c5d17](https://github.com/znat/parrotflow/commit/a0c5d17e66056d90dc32a76a841bef7ec9239dda))

## [0.6.0](https://github.com/znat/parrotflow/compare/v0.5.0...v0.6.0) (2026-08-13)


### Features

* the final permissions screen invites you to dictate, live ([#135](https://github.com/znat/parrotflow/issues/135)) ([0dd54fc](https://github.com/znat/parrotflow/commit/0dd54fc6dd062dfa8a3acff5645a01514f4b8efb))
* warm up the transcriber at launch, not on first dictation ([#132](https://github.com/znat/parrotflow/issues/132)) ([28d7676](https://github.com/znat/parrotflow/commit/28d7676a017fa81f7709ac369ebfc3f8d2e2c00a))


### Fixes

* check Input Monitoring before taking the offer's keys ([#136](https://github.com/znat/parrotflow/issues/136)) ([fc86338](https://github.com/znat/parrotflow/commit/fc86338720e3b173a151d4afa21a3600a8f950b7))
* close the launch-time gap in llm.keep_loaded warm-up ([#131](https://github.com/znat/parrotflow/issues/131)) ([317aa5f](https://github.com/znat/parrotflow/commit/317aa5fe1054e3a10d058a2b5295e487a88693cb))
* give config.yaml live-reload 10s before it interrupts you ([#129](https://github.com/znat/parrotflow/issues/129)) ([514dc58](https://github.com/znat/parrotflow/commit/514dc581808392dce267955053f222815a876649))
* seed config.yaml from config.example.yaml, add --warm-models and default Ollama install ([#133](https://github.com/znat/parrotflow/issues/133)) ([8b1b4d9](https://github.com/znat/parrotflow/commit/8b1b4d9c1f776550b7bd68d37e3ae712f2fd052e))

## [0.5.0](https://github.com/znat/parrotflow/compare/v0.4.0...v0.5.0) (2026-08-13)


### Features

* a Bluetooth microphone says so, once ([#115](https://github.com/znat/parrotflow/issues/115)) ([84db292](https://github.com/znat/parrotflow/commit/84db292071713afeb612c5206f1e8ca37ad63e1e))
* a click or a key past the offer's own dismisses it ([#126](https://github.com/znat/parrotflow/issues/126)) ([04aedfe](https://github.com/znat/parrotflow/commit/04aedfec6ebdd68b77d1ad171335c72d36282620))
* a dictation you can stop, and one that will not land in the wrong window ([#51](https://github.com/znat/parrotflow/issues/51)) ([97e7301](https://github.com/znat/parrotflow/commit/97e7301abd173625395a550829b869fd5c741a3f))
* a menu of the things you cannot already do with the hotkey ([#18](https://github.com/znat/parrotflow/issues/18)) ([c1ce1a3](https://github.com/znat/parrotflow/commit/c1ce1a3c57a2e08af7e3b885c0fe80e701e26efc))
* a name may claim two places in a sentence, not six ([#66](https://github.com/znat/parrotflow/issues/66)) ([0aaaf5c](https://github.com/znat/parrotflow/commit/0aaaf5c48d26cabfd791eb649e670df840f14de0))
* a prompt can see what is on your screen ([#50](https://github.com/znat/parrotflow/issues/50)) ([5a76068](https://github.com/znat/parrotflow/commit/5a7606850c82777a5def6ef9664a5431ee56889a))
* a rendering is a sound, not only a spelling ([#65](https://github.com/znat/parrotflow/issues/65)) ([01a9d66](https://github.com/znat/parrotflow/commit/01a9d66a40090004b608d0c755272a1ac5c0de35))
* a stage can tell the next one what it just did ([#48](https://github.com/znat/parrotflow/issues/48)) ([0501f44](https://github.com/znat/parrotflow/commit/0501f44312615812da44d4fc392dfe2e8913d85a))
* a stage that undoes corrections the speaker did not mean ([#55](https://github.com/znat/parrotflow/issues/55)) ([0d4bb60](https://github.com/znat/parrotflow/commit/0d4bb60f195a8ce66a33e2cb5ed6f0c5639b7801))
* a transform can be a program of your own ([#23](https://github.com/znat/parrotflow/issues/23)) ([ff21615](https://github.com/znat/parrotflow/commit/ff21615689cbab25795c5b54a58c9fb951232a1a))
* a transform can say what it is doing while it does it ([#24](https://github.com/znat/parrotflow/issues/24)) ([4fdc1c2](https://github.com/znat/parrotflow/commit/4fdc1c24c50541879d87d9c58d40c8a447fdf472))
* a transform is a folder, and it brings its own things with it ([#41](https://github.com/znat/parrotflow/issues/41)) ([2f58b7a](https://github.com/znat/parrotflow/commit/2f58b7ac9d34baf5468f3392c838077de80d82fc))
* a vocabulary that is learnt rather than written ([#52](https://github.com/znat/parrotflow/issues/52)) ([8410962](https://github.com/znat/parrotflow/commit/8410962e3014883ba7820def16f3f3c5705890fc))
* dictation reaches the apps that answer nothing ([#118](https://github.com/znat/parrotflow/issues/118)) ([9d6762d](https://github.com/znat/parrotflow/commit/9d6762d4ac5f6984ac112154ab5a5e7ea5c7704a))
* keep what the decoder knew, not just what it said ([#37](https://github.com/znat/parrotflow/issues/37)) ([5821568](https://github.com/znat/parrotflow/commit/5821568e5334cc436322d28cbfa22d5419ca2696))
* let a correction be asked for inside a dictation ([#19](https://github.com/znat/parrotflow/issues/19)) ([929192a](https://github.com/znat/parrotflow/commit/929192a1bd28d7482f6ceae3182fd1282840098b))
* make text and audio logging configurable, audio off by default ([#121](https://github.com/znat/parrotflow/issues/121)) ([28149e3](https://github.com/znat/parrotflow/commit/28149e343f5067124eb75ddb1d0c4a0c2d1a2d1e))
* measure whether the acoustic score block carries any signal ([#73](https://github.com/znat/parrotflow/issues/73)) ([78d7ba2](https://github.com/znat/parrotflow/commit/78d7ba2eb924fe7eefa2390a28295bffddeb109f))
* one pill for the whole dictation, and an offer to fix it ([#58](https://github.com/znat/parrotflow/issues/58)) ([841c829](https://github.com/znat/parrotflow/commit/841c829beec47cdac77d32024fe4e0903c6b6e08))
* say "undo" and the last substitution goes back ([#39](https://github.com/znat/parrotflow/issues/39)) ([8ab4f88](https://github.com/znat/parrotflow/commit/8ab4f884a756fdc5147ddb01056ae041198f171e))
* seed example transforms from the repo; add punctuation and repetitions ([#128](https://github.com/znat/parrotflow/issues/128)) ([fb7e05c](https://github.com/znat/parrotflow/commit/fb7e05cb60b8254fac48e2d265f2cead49d82d68))
* settings is one row with two doors, and both open in your editor ([#46](https://github.com/znat/parrotflow/issues/46)) ([addf91b](https://github.com/znat/parrotflow/commit/addf91b85b4a1c1453474f57e5aa180f9a269027))
* the app has a face, and the menu bar a bird that follows the light ([#36](https://github.com/znat/parrotflow/issues/36)) ([cb7797a](https://github.com/znat/parrotflow/commit/cb7797adca3abe36f9fa298eb6f2c230b8fc1a46))
* the correction panel is the sentence you said, edited in place ([#117](https://github.com/znat/parrotflow/issues/117)) ([ebbba61](https://github.com/znat/parrotflow/commit/ebbba6180eeaaeabb57b82e2c355d3c33c579c45))
* the harness that scores a rewrite ships with the app ([#44](https://github.com/znat/parrotflow/issues/44)) ([4a45452](https://github.com/znat/parrotflow/commit/4a4545296521487343c15756e683301cc6e73904))
* the menu opens the config folder, not one folder inside it ([#103](https://github.com/znat/parrotflow/issues/103)) ([967f771](https://github.com/znat/parrotflow/commit/967f7714fd970a0754fcbbc64b3e3477ed3c834a))
* the menu says which microphone the next press will use ([#34](https://github.com/znat/parrotflow/issues/34)) ([c2880f5](https://github.com/znat/parrotflow/commit/c2880f5923da74e596ac9190f1ec74669f90dd5c))
* the mic stays open a moment after you let go ([#25](https://github.com/znat/parrotflow/issues/25)) ([cab9fb5](https://github.com/znat/parrotflow/commit/cab9fb584037e079141786eab98c777c970276ff))
* the name judge takes one verdict per substitution ([#102](https://github.com/znat/parrotflow/issues/102)) ([c509721](https://github.com/znat/parrotflow/commit/c5097214cdb539554b0b6b099b9152b6a616bea0))
* the offer fades rather than vanishing ([#111](https://github.com/znat/parrotflow/issues/111)) ([c50fd44](https://github.com/znat/parrotflow/commit/c50fd44af9fd261ba41029fa66a5ec2b1745be0e))
* the offer follows every dictation, and a command rewrites in place ([#113](https://github.com/znat/parrotflow/issues/113)) ([06b25ad](https://github.com/znat/parrotflow/commit/06b25ad44f8cb36f95b92685fc79090ede178069))
* the offer names commands, and you can click them ([#109](https://github.com/znat/parrotflow/issues/109)) ([d9b68ee](https://github.com/znat/parrotflow/commit/d9b68ee60bb0ea0eb5cbb94a11a0fec90aea0f8e))
* the offer takes its own keys ([#110](https://github.com/znat/parrotflow/issues/110)) ([3634d2b](https://github.com/znat/parrotflow/commit/3634d2b1bad1b84edb502823a35739361a9b4dcb))
* the pill finds the words in an app that has no caret ([#107](https://github.com/znat/parrotflow/issues/107)) ([051b489](https://github.com/znat/parrotflow/commit/051b4894134b1d4d2aca82889e581b97a537fae6))
* the pill opens where the words will land ([#106](https://github.com/znat/parrotflow/issues/106)) ([557d53f](https://github.com/znat/parrotflow/commit/557d53fabc67fbe548b28f8e6c67f09f36705f69))
* the pill shows which app it is about to write into ([#27](https://github.com/znat/parrotflow/issues/27)) ([#29](https://github.com/znat/parrotflow/issues/29)) ([b01f6f7](https://github.com/znat/parrotflow/commit/b01f6f7053337cdb045089ebb02eadd79c745ae4))
* the surfaces are glass, and they throw light ([#59](https://github.com/znat/parrotflow/issues/59)) ([bbfd049](https://github.com/znat/parrotflow/commit/bbfd04913d832500aefd7d4787ae8c8a994b6c4f))
* the surfaces go near-black, and the plumage comes down a step ([#108](https://github.com/znat/parrotflow/issues/108)) ([bbfa3ac](https://github.com/znat/parrotflow/commit/bbfa3ac49ac3ce051fc2d3a9c22cdf699feae725))
* the vocabulary proposes, and a native judge decides ([#63](https://github.com/znat/parrotflow/issues/63)) ([62e5bcc](https://github.com/znat/parrotflow/commit/62e5bccd6e7f9f2a29df0d2cea20e367e4cce1f7))
* the words go to the clipboard when there is nowhere to type them ([#31](https://github.com/znat/parrotflow/issues/31)) ([9079fd3](https://github.com/znat/parrotflow/commit/9079fd3956e0507c761c7a679e8d91005bcd5428))
* two corrections in one breath, or describe the change instead of spelling it ([#21](https://github.com/znat/parrotflow/issues/21)) ([5df2534](https://github.com/znat/parrotflow/commit/5df253437d4f5181368fc48ab495db2ae8c872af))
* two skills for building and calibrating a vocabulary ([#57](https://github.com/znat/parrotflow/issues/57)) ([f826c02](https://github.com/znat/parrotflow/commit/f826c0287dbb450a3c0dfc127eef0d7a7573f5a1))
* two thresholds, so offering and writing stop sharing a number ([#64](https://github.com/znat/parrotflow/issues/64)) ([d904cf7](https://github.com/znat/parrotflow/commit/d904cf7028239dbcbb4f3a876c93abdfb80f744a))
* writing prompts, and a permissions walk that explains itself ([#30](https://github.com/znat/parrotflow/issues/30)) ([aa136e4](https://github.com/znat/parrotflow/commit/aa136e4c4ef0f62b7b398a89187c136ca8ef0430))


### Fixes

* a correction that landed is no longer undone by the check behind it ([#105](https://github.com/znat/parrotflow/issues/105)) ([f97436e](https://github.com/znat/parrotflow/commit/f97436edc301e3df2eb5d89f5ef5c865e2eda7ae))
* a dictation that is still working says so on screen ([#35](https://github.com/znat/parrotflow/issues/35)) ([83534be](https://github.com/znat/parrotflow/commit/83534bea5dddc3addcc2c6d297963f5695bb8672))
* a long pause no longer takes the end of the clip with it ([#47](https://github.com/znat/parrotflow/issues/47)) ([1c7e081](https://github.com/znat/parrotflow/commit/1c7e08107ca9b6f2a57f033fa875b4594a26d2f8))
* a microphone that changes no longer records silence in the dark ([#104](https://github.com/znat/parrotflow/issues/104)) ([8d6bad9](https://github.com/znat/parrotflow/commit/8d6bad9e72ea89d148c52db7b25c0e8d2b4e75f2)), closes [#95](https://github.com/znat/parrotflow/issues/95)
* a microphone that changes takes neither the hotkey nor the app with it ([#124](https://github.com/znat/parrotflow/issues/124)) ([a801897](https://github.com/znat/parrotflow/commit/a801897fc380f44296128c5d54e518bd3507a9d5)), closes [#123](https://github.com/znat/parrotflow/issues/123)
* a possessive survives the substitution that spells the name ([#88](https://github.com/znat/parrotflow/issues/88)) ([c2cb15c](https://github.com/znat/parrotflow/commit/c2cb15c564500d6d10e8c86533dd8bdf0d29806e))
* a substitution replaces the words instead of landing after them ([#38](https://github.com/znat/parrotflow/issues/38)) ([1e0f5f3](https://github.com/znat/parrotflow/commit/1e0f5f32d0a9e63cb0f2735e15a9450ce18df778))
* a transform you can run is a transform you can ask for ([#45](https://github.com/znat/parrotflow/issues/45)) ([78db4f5](https://github.com/znat/parrotflow/commit/78db4f5745d0f6b3cd75814bfc9a322a982a8c29))
* an email ends where the speaker stopped, never on a name they did not say ([#33](https://github.com/znat/parrotflow/issues/33)) ([c21283e](https://github.com/znat/parrotflow/commit/c21283eac9b2216d83fc94bb24a1fb6838e9ca30))
* dictations that lose their ending, and a microphone that takes the hotkey with it ([#32](https://github.com/znat/parrotflow/issues/32)) ([13be319](https://github.com/znat/parrotflow/commit/13be319071c3fa7e9fb73706daec167588636919))
* F12 was measurement noise — one audio path, and a checksum at the seam ([#61](https://github.com/znat/parrotflow/issues/61)) ([fbc4069](https://github.com/znat/parrotflow/commit/fbc4069cad562601ee023b79621436fea870f5d0))
* stop a sentence about a parrot from being taken as a command ([#22](https://github.com/znat/parrotflow/issues/22)) ([c2168b3](https://github.com/znat/parrotflow/commit/c2168b3c72cb0bb697605655bd1640d8d09169a2))
* the judge counts a term's rules together, not one at a time ([#89](https://github.com/znat/parrotflow/issues/89)) ([ba75a81](https://github.com/znat/parrotflow/commit/ba75a8120be8ed6c10852ee7740a81df7a271f75))
* the judge harness says what it needs instead of raising ([#54](https://github.com/znat/parrotflow/issues/54)) ([0a2258d](https://github.com/znat/parrotflow/commit/0a2258d7752b33baea5d480184f55731dd149681))
* the judge takes the pre-rules transcript from replacements ([#86](https://github.com/znat/parrotflow/issues/86)) ([3ac1894](https://github.com/znat/parrotflow/commit/3ac1894d43e862d0343fce517cb7f44b21f23bb7))
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
