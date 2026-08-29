import time
import random
import httpx
from fastapi import FastAPI, HTTPException

app = FastAPI(title="zero-code-otel-demo")


@app.get("/")
async def root():
    return {"message": "hello from zero-code otel demo"}


@app.get("/work")
async def work():
    delay = random.uniform(0.05, 0.4)
    time.sleep(delay)
    return {"work_done": True, "delay_seconds": round(delay, 3)}


@app.get("/error")
async def error():
    raise HTTPException(status_code=500, detail="simulated failure")


@app.get("/call-external")
async def call_external():
    async with httpx.AsyncClient(timeout=10) as client:
        resp = await client.get("https://httpbin.org/get")
    return {"status_code": resp.status_code}
