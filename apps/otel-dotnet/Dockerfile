FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build

WORKDIR /src

COPY app/*.csproj ./app/
RUN dotnet restore ./app/*.csproj

COPY app/ ./app/

RUN dotnet publish ./app/*.csproj \
    -c Release \
    -o /out

FROM mcr.microsoft.com/dotnet/aspnet:10.0

WORKDIR /app

ARG OTEL_VERSION=1.16.0

ENV OTEL_DOTNET_AUTO_HOME=/otel-dotnet-auto

ADD https://github.com/open-telemetry/opentelemetry-dotnet-instrumentation/releases/download/v${OTEL_VERSION}/otel-dotnet-auto-install.sh /tmp/otel-dotnet-auto-install.sh

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        curl \
        unzip \
    && sh /tmp/otel-dotnet-auto-install.sh \
    && chmod +x /otel-dotnet-auto/instrument.sh \
    && rm -rf /var/lib/apt/lists/* /tmp/otel-dotnet-auto-install.sh

COPY --from=build /out .

ENV ASPNETCORE_URLS=http://+:8080

EXPOSE 8080

ENV OTEL_SERVICE_NAME=otel-dotnet-demo \
    OTEL_TRACES_EXPORTER=console \
    OTEL_METRICS_EXPORTER=console \
    OTEL_LOGS_EXPORTER=console

ENTRYPOINT ["/otel-dotnet-auto/instrument.sh", "dotnet", "app.dll"]

