FROM nimlang/choosenim

RUN apt install -y libsqlite3-dev sqlite3

RUN choosenim 2.0.2 && \
    nimble install -y nimble

RUN mkdir /code
COPY ./markinim.nimble /code

WORKDIR /code
RUN nimble install --depsOnly -y
# cache dependencies if code gets modified

COPY . /code

# RUN nimble install -y
RUN nim c -o:markinim src/markinim.nim

CMD [ "./markinim" ]
