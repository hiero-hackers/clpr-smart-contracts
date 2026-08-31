import http2 from "node:http2";

function grpcFrame(proto: Buffer): Buffer {
    const frame = Buffer.allocUnsafe(5 + proto.length);
    frame[0] = 0;
    frame.writeUInt32BE(proto.length, 1);
    proto.copy(frame, 5);
    return frame;
}

export interface GrpcUnaryResult {
    status: number;
    message: string;
    body: Buffer;
}

/// Minimal gRPC unary client (application/grpc+proto over HTTP/2).
export function grpcUnary(hostPort: string, path: string, request: Buffer): Promise<GrpcUnaryResult> {
    const [host, portStr] = hostPort.includes(":") ? hostPort.split(":") : [hostPort, "40840"];
    const port = Number(portStr);
    const authority = `${host}:${port}`;

    return new Promise((resolve, reject) => {
        const client = http2.connect(`http://${authority}`);
        client.on("error", reject);

        const stream = client.request({
            ":method": "POST",
            ":path": path,
            ":scheme": "http",
            ":authority": authority,
            "content-type": "application/grpc+proto",
            "te": "trailers"
        });

        stream.write(grpcFrame(request));
        stream.end();

        const chunks: Buffer[] = [];
        let status = -1;
        let message = "";

        stream.on("data", (chunk: Buffer) => chunks.push(chunk));
        stream.on("trailers", (headers) => {
            status = Number(headers["grpc-status"] ?? -1);
            message = String(headers["grpc-message"] ?? "");
        });
        stream.on("end", () => {
            client.close();
            const buf = Buffer.concat(chunks);
            const body = buf.length >= 5 ? buf.subarray(5, 5 + buf.readUInt32BE(1)) : Buffer.alloc(0);
            resolve({status, message, body});
        });
        stream.on("error", (err: Error) => {
            client.close();
            reject(err);
        });
    });
}

export function grpcOk(result: GrpcUnaryResult): boolean {
    return result.status === 0;
}
