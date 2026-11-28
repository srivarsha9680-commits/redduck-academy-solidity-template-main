
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { network } from "hardhat";
import { parseEther, getAddress } from "viem";
import { MerkleTree, type AirdropEntry } from "./merkle.ts";
import { signAirdropClaim } from "./signatures.ts";

const { viem } = await network.connect();

describe("MerkleAirdrop", function () {
  async function deployFixture() {
    const [deployer, alice, bob, carol, signer, dave, eve] =
      await viem.getWalletClients();

    const entries: AirdropEntry[] = [
      { account: getAddress(alice.account.address), amount: parseEther("100") },
      { account: getAddress(bob.account.address), amount: parseEther("200") },
      { account: getAddress(carol.account.address), amount: parseEther("300") },
      { account: getAddress(eve.account.address), amount: parseEther("50") },
    ];

    const tree = new MerkleTree(entries);

    const token = await viem.deployContract("Token", [
      "Redduck Token",
      "RDDK",
      parseEther("100000000000000"),
    ]);

    const airdrop = await viem.deployContract("MerkleAirdrop", [
      token.address,
      tree.root,
      signer.account.address,
    ]);

    await token.write.transfer(
      [airdrop.address, parseEther("100000000000000")],
      { account: deployer.account }
    );

    return {
      entries,
      tree,
      token,
      airdrop,
      deployer,
      alice,
      bob,
      carol,
      signer,
      dave,
      eve,
    };
  }

  // 1. Successful Merkle claim
  it("lets an eligible account claim its allocation with a Merkle proof", async function () {
    const { entries, tree, token, airdrop, alice } = await deployFixture();

    const proof = tree.getProof(0);
    const { account, amount } = entries[0];

    await airdrop.write.claim([amount, proof], {
      account: alice.account,
    });

    assert.equal(await token.read.balanceOf([account]), amount);
    assert.equal(await airdrop.read.hasClaimed([account]), true);
  });

  // 2. Successful signature claim
  it("lets an authorized account claim with an admin signature (not on the Merkle list)", async function () {
    const { token, airdrop, signer, dave } = await deployFixture();

    const daveAddr = getAddress(dave.account.address);
    const amount = parseEther("50");

    const { v, r, s } = await signAirdropClaim(
      signer,
      daveAddr,
      amount,
      airdrop.address
    );

    await airdrop.write.claimWithSignature([amount, v, r, s], {
      account: dave.account,
    });

    assert.equal(await token.read.balanceOf([daveAddr]), amount);
    assert.equal(await airdrop.read.hasClaimed([daveAddr]), true);
  });

  // 3. Invalid Merkle proof
  it("rejects an invalid Merkle proof", async function () {
    const { airdrop, alice } = await deployFixture();

    await assert.rejects(
      airdrop.write.claim([parseEther("100"), []], {
        account: alice.account,
      }),
      /InvalidProof/
    );
  });

  // 4. Wrong signer
  it("rejects a signature from the wrong signer", async function () {
    const { airdrop, deployer, dave } = await deployFixture();

    const amount = parseEther("50");
    const daveAddr = getAddress(dave.account.address);

    const { v, r, s } = await signAirdropClaim(
      deployer,
      daveAddr,
      amount,
      airdrop.address
    );

    await assert.rejects(
      airdrop.write.claimWithSignature([amount, v, r, s], {
        account: dave.account,
      }),
      /InvalidSignature/
    );
  });

  // 5. Wrong recipient or amount
  it("rejects a signature used for the wrong recipient or amount", async function () {
    const { airdrop, signer, dave, eve } = await deployFixture();

    const amount = parseEther("50");
    const daveAddr = getAddress(dave.account.address);
    const eveAddr = getAddress(eve.account.address);

    const daveSignature = await signAirdropClaim(
      signer,
      daveAddr,
      amount,
      airdrop.address
    );

    await assert.rejects(
      airdrop.write.claimWithSignature(
        [
          amount,
          daveSignature.v,
          daveSignature.r,
          daveSignature.s,
        ],
        { account: eve.account }
      ),
      /InvalidSignature/
    );

    await assert.rejects(
      airdrop.write.claimWithSignature(
        [
          amount + 1n,
          daveSignature.v,
          daveSignature.r,
          daveSignature.s,
        ],
        { account: dave.account }
      ),
      /InvalidSignature/
    );

    assert.equal(await airdrop.read.hasClaimed([eveAddr]), false);
  });

  // 6. Signature bound to deployed contract
  it("binds a signature to the deployed airdrop contract", async function () {
    const { airdrop, tree, signer, dave, deployer } =
      await deployFixture();

    const amount = parseEther("50");
    const daveAddr = getAddress(dave.account.address);

    const secondToken = await viem.deployContract("Token", [
      "Second Redduck Token",
      "SRDDK",
      parseEther("1000000"),
    ]);

    const secondAirdrop = await viem.deployContract("MerkleAirdrop", [
      secondToken.address,
      tree.root,
      signer.account.address,
    ]);

    await secondToken.write.transfer(
      [secondAirdrop.address, parseEther("1000000")],
      { account: deployer.account }
    );

    const signature = await signAirdropClaim(
      signer,
      daveAddr,
      amount,
      airdrop.address
    );

    await assert.rejects(
      secondAirdrop.write.claimWithSignature(
        [
          amount,
          signature.v,
          signature.r,
          signature.s,
        ],
        { account: dave.account }
      ),
      /InvalidSignature/
    );
  });

  // 7. Shared claimed state between both paths
  it("shares the claimed state between both claim paths", async function () {
    const { entries, tree, airdrop, signer, alice } =
      await deployFixture();

    const { account, amount } = entries[0];
    const proof = tree.getProof(0);

    await airdrop.write.claim([amount, proof], {
      account: alice.account,
    });

    const signature = await signAirdropClaim(
      signer,
      account,
      amount,
      airdrop.address
    );

    await assert.rejects(
      airdrop.write.claimWithSignature(
        [
          amount,
          signature.v,
          signature.r,
          signature.s,
        ],
        { account: alice.account }
      ),
      /AlreadyClaimed/
    );

    await assert.rejects(
      airdrop.write.claim([amount, proof], {
        account: alice.account,
      }),
      /AlreadyClaimed/
    );
  });

  // 13. Verify Claimed event for Merkle claim
  it("emits the Claimed event after a successful Merkle claim", async function () {
    const { entries, tree, airdrop, alice } = await deployFixture();

    const { account, amount } = entries[0];
    const proof = tree.getProof(0);

    await viem.assertions.emitWithArgs(
      airdrop.write.claim([amount, proof], {
        account: alice.account,
      }),
      airdrop,
      "Claimed",
      [account, amount]
    );
  });

  // 14. Verify Claimed event for signature claim
  it("emits the Claimed event after a successful signature claim", async function () {
    const { airdrop, signer, dave } = await deployFixture();

    const account = getAddress(dave.account.address);
    const amount = parseEther("50");

    const { v, r, s } = await signAirdropClaim(
      signer,
      account,
      amount,
      airdrop.address
    );

    await viem.assertions.emitWithArgs(
      airdrop.write.claimWithSignature([amount, v, r, s], {
        account: dave.account,
      }),
      airdrop,
      "Claimed",
      [account, amount]
    );
  });

  // 14. Verify replay protection for signature claim
  it("rejects a second signature claim after a successful claim", async function () {
    const { airdrop, signer, dave } = await deployFixture();

    const account = getAddress(dave.account.address);
    const amount = parseEther("50");

    const { v, r, s } = await signAirdropClaim(
      signer,
      account,
      amount,
      airdrop.address
    );

    await airdrop.write.claimWithSignature([amount, v, r, s], {
      account: dave.account,
    });

    await assert.rejects(
      airdrop.write.claimWithSignature([amount, v, r, s], {
        account: dave.account,
      }),
      /AlreadyClaimed/
    );

    assert.equal(await airdrop.read.hasClaimed([account]), true);
  });
});
