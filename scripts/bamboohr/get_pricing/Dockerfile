# Hosted BambooHR Get Pricing BFF (bearer or JWT env auth — no CCI keychain).
FROM python:3.13-slim
WORKDIR /app
RUN pip install --no-cache-dir "PyJWT[crypto]>=2.8"
COPY scripts/bamboohr/get_pricing/ /app/
ENV PORT=8765 BFF_HOST=0.0.0.0
EXPOSE 8765
CMD ["python", "server.py", "--host", "0.0.0.0", "--port", "8765"]
