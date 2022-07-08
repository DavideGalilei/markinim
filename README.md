# WIP Readme
This is the @MarkinimBot Telegram bot's source code. It's a bit messy (it was never meant to be open source at the beginning) so it needs a cleanup, but it works. Memory usage and performance are pretty good. It uses sqlite.

# Deploy
Install required dependencies:

```shell
$ nimble install
```

Then create a `secret.ini` file which looks like this, where admin is your Telegram user id, and token is the bot token obtainable from @BotFather.

```ini
[config]
token = "1234:abcdefg"
admin = 123456
```

```shell
$ nim c src/markinim -o markinim
$ ./markinim
```
or Docker

`$ docker run --rm -v=(pwd)/markov.db:/code/markov.db -v=(pwd)/secret.ini:/code/secret.ini markinim`

or Docker Compose

```
version: '3.3'
services:
    markinim:
        volumes:
            - '(pwd)/markov.db:/code/markov.db'
            - '(pwd)/secret.ini:/code/secret.ini'
        image: markinim
```
