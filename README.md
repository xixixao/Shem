# Shem

Shem is a new compiled-to-JS, statically typed, pure-by-default functional programming language. The semantics are based on [Haskell](https://www.haskell.org/) but the language evaluates strictly in a similar way to [PureScript](http://purescript.org/). The syntax is S-expressions-based, allowing for a full-blown LISP-like macro system. Shem's prelude includes a full-featured, highly-polymorphic collections library backed by [ImmutableJS](http://facebook.github.io/immutable-js).

The language has been designed for the use within its custom built IDE, [Golem](https://github.com/xixixao/Golem) available at [http://xixixao.github.io/Golem](http://xixixao.github.io/Golem), inspired by [Bret Victor](http://worrydream.com/).

![A screenshot of the Golem IDE showing the source and debugging of a binary search function](http://shem.io/img/screen-shot-binarysearch.png)

![A screenshot of the Golem IDE with a running animation](http://shem.io/img/screen-shot-star.png)

**Here Be Lions**

## Use without Golem

Clone this repo, go to the folder, then

```bash
npm install
npm run build
```

To run a single file

```bash
echo '_ (.log (global "console") "Hello world!")' > test.shem
bin/shem test.shem
```

To compile a single file to JavaScript

```
bin/shem -c test.shem
```

To run a module
```bash
mkdir test-modules
echo 'message "Hello, hello, world!"' > test-modules/Hello.shem
echo '[message] (req ./Hello) _ (.log (global "console") message)' > test-modules/index.shem
bin/shem test-modules
```

To compile a module
```bash
bin/shem -o test-modules-out-dir -c test-modules
```

## Demo

https://www.youtube.com/watch?v=HnZipJOan54 (for now)


> *I am providing code in this repository to you under an open source license. Because this is my personal repository, the license you receive to my code is from me and not from my employer (Facebook).*
