FROM nimlang/nim:1.6.2

RUN mkdir /code
COPY ./markinim.nimble /code

WORKDIR /code
RUN nimble install --depsOnly -y
# cache dependencies if code gets modified

COPY . /code

# RUN nimble install -y
RUN nim c -o:markinim src/markinim.nim

CMD [ "./markinim" ]
