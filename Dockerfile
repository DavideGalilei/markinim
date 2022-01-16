FROM nimlang/nim:1.6.2

COPY . /code
WORKDIR /code

RUN nimble install -y
# RUN nim c -d:release -d:ssl -o:markinim src/markinim.nim

CMD [ "./markinim" ]
