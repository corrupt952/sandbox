export const handler = async (event: any, context: any, callback: any) => {
  return {
    statusCode: 200,
    body: JSON.stringify({
      "message": "Hello from Lambda!",
    }),
  }
}
