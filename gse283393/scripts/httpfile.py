import io, os, requests

class HTTPRangeFile(io.RawIOBase):
    """Minimal seekable read-only file over HTTP range requests."""
    def __init__(self, url, session=None, chunk=1 << 20):
        self.url = url
        self.s = session or requests.Session()
        r = self.s.head(url, allow_redirects=True, timeout=60)
        r.raise_for_status()
        self.size = int(r.headers["Content-Length"])
        self.pos = 0
        self.nreq = 0
        self.nbytes = 0

    def seekable(self): return True
    def readable(self): return True
    def tell(self): return self.pos

    def seek(self, off, whence=0):
        if whence == 0: self.pos = off
        elif whence == 1: self.pos += off
        else: self.pos = self.size + off
        return self.pos

    def read(self, n=-1):
        if n is None or n < 0:
            n = self.size - self.pos
        if n == 0 or self.pos >= self.size:
            return b""
        end = min(self.pos + n, self.size) - 1
        h = {"Range": f"bytes={self.pos}-{end}"}
        r = self.s.get(self.url, headers=h, timeout=300)
        r.raise_for_status()
        data = r.content
        self.pos += len(data)
        self.nreq += 1
        self.nbytes += len(data)
        return data

    def readinto(self, b):
        d = self.read(len(b))
        b[:len(d)] = d
        return len(d)
