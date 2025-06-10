import sys
import asyncio
import logging
from toolz import last
from HyREPL.session import sessions, Session
from HyREPL.bencode import decode
from hyrule import inc


async def handle_client(reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
    print("New client", file=sys.stderr)
    buf = bytearray()
    session = None
    loop = asyncio.get_running_loop()
    while True:
        try:
            data = await reader.read(1024)
        except OSError:
            break
        if not data:
            break
        buf.extend(data)
        while True:
            try:
                m, rest = decode(bytes(buf))
                buf[:] = rest
            except Exception:
                # Incomplete or invalid data
                break
            req = m
            sid = req.get("session")
            if session is None:
                session = sessions.get(sid)
                if session is None:
                    logging.debug("session not found and created: finding session id=%s", sid)
                    session = Session()
            if sid and session.uuid != sid:
                session = sessions.get(sid)
            if getattr(session, "loop", None) is None:
                session.loop = loop
            session.handle(req, writer)
            if not buf:
                break
    print("Client gone", file=sys.stderr)
    writer.close()
    try:
        await writer.wait_closed()
    except Exception:
        pass


async def start_server(ip: str = "127.0.0.1", port: int = 7888):
    return await asyncio.start_server(handle_client, ip, port)


async def main(*args: str):
    if "-h" in args or "--help" in args:
        print("Usage:\n  hyrepl [-d | --debug] [-h | --help] [<port>]\n\n" "Options:\n  -h, --help      Show this usage\n  -d, --debug     Debug mode (true/false) [default: false]\n  <port>          Port number [default: 7888]")
        return 0

    logging.basicConfig(
        level=logging.DEBUG if ("-d" in args or "--debug" in args) else logging.WARNING,
        format="%(levelname)s:%(module)s: %(message)s (at %(filename)s:%(lineno)d in %(funcName)s)",
    )

    logging.debug("Starting hyrepl: args=%s", args)

    port = 7888
    if len(args) > 0:
        try:
            port = int(last(args))
        except ValueError:
            port = 7888

    while True:
        try:
            server = await start_server("127.0.0.1", port)
        except OSError:
            port = inc(port)
        else:
            print(f"Listening on {port}", file=sys.stderr)
            async with server:
                await server.serve_forever()
            break


if __name__ == "__main__":
    asyncio.run(main(*sys.argv[1:]))
