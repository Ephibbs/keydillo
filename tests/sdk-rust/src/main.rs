// Checks whether Rust's async-openai sends requests to OPENAI_BASE_URL, the way `kd` sets it.
#[tokio::main]
async fn main() {
    let client = async_openai::Client::new();
    let r = client.models().list().await;
    println!("async-openai {:?}", r.err().map(|e| e.to_string()));
}
