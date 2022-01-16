FROM nimlang/nim

COPY . /code
WORKDIR /code

RUN nimble install

CMD [ "./markov" ]
