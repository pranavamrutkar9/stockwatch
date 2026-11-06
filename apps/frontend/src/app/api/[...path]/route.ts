import { NextRequest, NextResponse } from 'next/server';

async function proxyRequest(request: NextRequest, pathParts: string[]) {
  const backendBase = process.env.BACKEND_INTERNAL_URL || 'http://backend:4000';
  const subPath = pathParts.join('/');
  const targetUrl = `${backendBase}/api/${subPath}${request.nextUrl.search}`;

  const headers = new Headers(request.headers);
  headers.delete('host');

  try {
    const init: RequestInit = {
      method: request.method,
      headers,
    };

    if (request.method !== 'GET' && request.method !== 'HEAD') {
      const body = await request.text();
      init.body = body;
    }

    const res = await fetch(targetUrl, init);
    const responseBody = await res.text();

    return new NextResponse(responseBody, {
      status: res.status,
      statusText: res.statusText,
      headers: {
        'Content-Type': res.headers.get('Content-Type') || 'application/json',
      },
    });
  } catch (err) {
    return NextResponse.json(
      {
        statusCode: 502,
        error: 'Bad Gateway',
        message: `Failed to proxy request to backend: ${(err as Error).message}`,
      },
      { status: 502 },
    );
  }
}

export async function GET(request: NextRequest, { params }: { params: Promise<{ path: string[] }> }) {
  const { path } = await params;
  return proxyRequest(request, path);
}

export async function POST(request: NextRequest, { params }: { params: Promise<{ path: string[] }> }) {
  const { path } = await params;
  return proxyRequest(request, path);
}

export async function PATCH(request: NextRequest, { params }: { params: Promise<{ path: string[] }> }) {
  const { path } = await params;
  return proxyRequest(request, path);
}

