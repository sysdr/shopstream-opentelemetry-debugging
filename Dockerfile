FROM python:3.12-slim
WORKDIR /srv
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app/ app/
COPY tools/ tools/
COPY tests/ tests/
ENV PYTHONUNBUFFERED=1
# Large blocks come straight from the OS and go back when freed, so a cleared leak really releases memory.
ENV MALLOC_MMAP_THRESHOLD_=131072
CMD ["gunicorn", "-b", "0.0.0.0:8000", "-w", "1", "--threads", "16", "--timeout", "120", "app.main:app"]
