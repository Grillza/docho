FROM python:3.13-alpine
WORKDIR /app
COPY server.py .
ENV DOCHO_SYNC_DATA=/data PYTHONUNBUFFERED=1
VOLUME /data
EXPOSE 8090
USER 1000:1000
HEALTHCHECK --interval=60s --timeout=5s CMD wget -qO- http://127.0.0.1:8090/api/v1/health >/dev/null || exit 1
CMD ["python", "server.py"]
