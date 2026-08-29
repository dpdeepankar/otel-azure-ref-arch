using System.Net;
using System.Net.Http;

var builder = WebApplication.CreateBuilder(args);

var app = builder.Build();

app.MapGet("/", () =>
    Results.Ok(new
    {
        message = "hello from zero-code otel demo"
    }));

app.MapGet("/work", () =>
{
    var random = new Random();
    var delay = random.NextDouble() * 0.35 + 0.05;

    Thread.Sleep(TimeSpan.FromSeconds(delay));

    return Results.Ok(new
    {
        work_done = true,
        delay_seconds = Math.Round(delay, 3)
    });
});

app.MapGet("/error", () =>
{
    throw new InvalidOperationException("simulated failure");
});

app.MapGet("/call-external", async () =>
{
    using var client = new HttpClient();

    var response = await client.GetAsync("https://httpbin.org/get");

    return Results.Ok(new
    {
        status_code = (int)response.StatusCode
    });
});

app.Run();
