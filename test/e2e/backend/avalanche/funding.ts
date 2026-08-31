import { createPublicClient, createWalletClient, http, parseEther } from "viem";

/**
 * Avalanche's default test account on local networks.
 * This account has unlimited funds by default and is used to bootstrap funding.
 */
const EWOQ_KEY = "0x56289e99c94b6912bfc12adc093c9b51124f0dc54ac7a766b2bc5ccf558d8027";
const EWOQ_ADDRESS = "0x8db97C7cEcE249c2b98bDC0226Cc4C2A57BF52FC";

/**
 * Fund a test account from the ewoq account during bootstrap.
 * Called once per test run to ensure test accounts have sufficient funds.
 */
export async function fundAccountFromEwoq(
	rpcUrl: string,
	targetAccount: `0x${string}`,
	amount: string = "1000000000000000000", // 1 ETH in wei
): Promise<void> {
	const publicClient = createPublicClient({ transport: http(rpcUrl) });
	const walletClient = createWalletClient({ account: EWOQ_ADDRESS, transport: http(rpcUrl) });

	// Check if ewoq has balance
	const ewoqBalance = await publicClient.getBalance({ address: EWOQ_ADDRESS });
	if (ewoqBalance === 0n) {
		throw new Error(
			`EWOQ account (${EWOQ_ADDRESS}) has no balance. Avalanche local network not properly initialized.`,
		);
	}

	// Check if target already has funds
	const targetBalance = await publicClient.getBalance({ address: targetAccount });
	if (targetBalance > 0n) {
		console.log(`[avalanche-funding] ${targetAccount} already funded (balance: ${targetBalance})`);
		return;
	}

	// Send funds from ewoq to target
	const hash = await walletClient.sendTransaction({
		account: EWOQ_ADDRESS,
		to: targetAccount,
		value: BigInt(amount),
		privateKey: EWOQ_KEY,
	});

	await publicClient.waitForTransactionReceipt({ hash });
	console.log(`[avalanche-funding] Funded ${targetAccount} with ${amount} wei`);
}

/**
 * Fund multiple test accounts from ewoq.
 */
export async function fundTestAccounts(
	rpcUrl: string,
	accounts: `0x${string}`[],
	amountPerAccount?: string,
): Promise<void> {
	for (const account of accounts) {
		await fundAccountFromEwoq(rpcUrl, account, amountPerAccount);
	}
}
