// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*
  Dispensary NFT Backpack — Simplified (demo)
  ------------------------------------------------
  Idea (built originally in May 2019):
  - Each customer holds a "backpack" NFT.
  - Every retail purchase appends an "item" attribute (product, category, terpene).
  - Over time, the wallet develops a terpene profile used for personalization + marketing insights.
  - POS systems (or a relay) are allowed to call recordPurchase().

  Notes:
  - tokenURI here is "dynamic" (computed on-chain): it reflects the number of items
    and the current top terpene for that backpack at read-time.
  - In production, you'd likely use an off-chain renderer/metadata service + cache.
*/

import {ERC721} from "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {Strings} from "openzeppelin-contracts/contracts/utils/Strings.sol";

library Base64 {
    // OpenZeppelin Base64 (shortened) — MIT
    bytes internal constant TABLE = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    function encode(bytes memory data) internal pure returns (string memory) {
        if (data.length == 0) return "";
        string memory table = string(TABLE);
        uint256 encodedLen = 4 * ((data.length + 2) / 3);
        string memory result = new string(encodedLen + 32);
        assembly {
            mstore(result, encodedLen)
            let tablePtr := add(table, 1)
            let dataPtr := data
            let endPtr := add(dataPtr, mload(data))
            let resultPtr := add(result, 32)
            for {} lt(dataPtr, endPtr) {}
            {
                dataPtr := add(dataPtr, 3)
                let input := mload(dataPtr)
                mstore8(resultPtr, mload(add(tablePtr, and(shr(18, input), 0x3F))))
                resultPtr := add(resultPtr, 1)
                mstore8(resultPtr, mload(add(tablePtr, and(shr(12, input), 0x3F))))
                resultPtr := add(resultPtr, 1)
                mstore8(resultPtr, mload(add(tablePtr, and(shr( 6, input), 0x3F))))
                resultPtr := add(resultPtr, 1)
                mstore8(resultPtr, mload(add(tablePtr, and(        input , 0x3F))))
                resultPtr := add(resultPtr, 1)
            }
            switch mod(mload(data), 3)
            case 1 { mstore(sub(resultPtr, 2), shl(240, 0x3d3d)) } // '=='
            case 2 { mstore(sub(resultPtr, 1), shl(248, 0x3d)) }   // '='
        }
        return result;
    }
}

contract BackpackNFT is ERC721, Ownable {
    using Strings for uint256;

    // Authorized POS callers that can append purchases
    mapping(address => bool) public posAllowed;

    // Purchase "items" held inside each backpack
    struct Item {
        string product;    // e.g., "Gorilla Glue 3.5g"
        string category;   // e.g., "Flower", "Vape", "Gummy"
        string terpene;    // e.g., "Limonene", "Myrcene"
        uint256 amount;    // optional raw units (mg/qty); used for scoring
        uint256 timestamp; // block timestamp at append
    }

    // tokenId => items[]
    mapping(uint256 => Item[]) internal _items;

    // tokenId => terpene => cumulative score
    mapping(uint256 => mapping(string => uint256)) internal _terpeneScore;

    // Simple incremental mint
    uint256 public nextId;

    // Optional: base image used in generated JSON (you can host a static backpack PNG)
    string public baseImageURI;

    event POSAuthorized(address indexed pos, bool allowed);
    event BackpackMinted(address indexed to, uint256 indexed tokenId);
    event PurchaseRecorded(
        uint256 indexed tokenId,
        string product,
        string category,
        string terpene,
        uint256 amount
    );

    constructor(string memory _baseImageURI) ERC721("Dispensary Backpack", "BPACK") {
        baseImageURI = _baseImageURI;
    }

    // ----------------------
    // Admin / POS management
    // ----------------------
    function setPOS(address pos, bool allowed) external onlyOwner {
        posAllowed[pos] = allowed;
        emit POSAuthorized(pos, allowed);
    }

    function setBaseImageURI(string calldata uri) external onlyOwner {
        baseImageURI = uri;
    }

    // ---------------
    // Minting (demo)
    // ---------------
    function mintBackpack(address to) external onlyOwner returns (uint256 tokenId) {
        tokenId = ++nextId;
        _safeMint(to, tokenId);
        emit BackpackMinted(to, tokenId);
    }

    // ------------------------------------
    // Append retail purchases to a backpack
    // ------------------------------------
    function recordPurchase(
        uint256 tokenId,
        string calldata product,
        string calldata category,
        string calldata terpene,
        uint256 amount // arbitrary units; used to influence terpene score
    ) external {
        require(_exists(tokenId), "Invalid token");
        require(posAllowed[msg.sender] || ownerOf(tokenId) == msg.sender, "Not authorized");

        _items[tokenId].push(Item({
            product: product,
            category: category,
            terpene: terpene,
            amount: amount,
            timestamp: block.timestamp
        }));

        // Increase terpene score (simple additive model)
        uint256 weight = amount == 0 ? 1 : amount;
        _terpeneScore[tokenId][terpene] += weight;

        emit PurchaseRecorded(tokenId, product, category, terpene, amount);
    }

    // ------------------------
    // Public read-only helpers
    // ------------------------
    function itemsCount(uint256 tokenId) external view returns (uint256) {
        require(_exists(tokenId), "Invalid token");
        return _items[tokenId].length;
    }

    function getItem(uint256 tokenId, uint256 index) external view returns (Item memory) {
        require(_exists(tokenId), "Invalid token");
        require(index < _items[tokenId].length, "OOB");
        return _items[tokenId][index];
    }

    // Compute the top terpene on the fly (small loops = okay for view function)
    function topTerpene(uint256 tokenId) public view returns (string memory name, uint256 score) {
        require(_exists(tokenId), "Invalid token");
        // To keep it simple on-chain, we iterate the items and track the max.
        // In production, you might cache keys to avoid repeated scans.
        Item[] memory list = _items[tokenId];
        // Naive single-pass: collect last seen unique terpenes into memory arrays
        string[] memory keys = new string[](list.length);
        uint256 unique;
        for (uint256 i = 0; i < list.length; i++) {
            string memory t = list[i].terpene;
            bool seen;
            for (uint256 k = 0; k < unique; k++) {
                if (keccak256(bytes(keys[k])) == keccak256(bytes(t))) { seen = true; break; }
            }
            if (!seen) { keys[unique++] = t; }
        }
        for (uint256 k = 0; k < unique; k++) {
            uint256 s = _terpeneScore[tokenId][keys[k]];
            if (s > score) { score = s; name = keys[k]; }
        }
    }

    // ----------------
    // Dynamic tokenURI
    // ----------------
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        require(_exists(tokenId), "Invalid token");

        (string memory tTerp, uint256 tScore) = topTerpene(tokenId);
        uint256 count = _items[tokenId].length;

        // Build a lightweight JSON with a few dynamic parts
        bytes memory json = abi.encodePacked(
            "{",
                "\"name\":\"Backpack #", tokenId.toString(), "\",",
                "\"description\":\"Dynamic NFT backpack linked to dispensary purchases (prototype).\",",
                "\"image\":\"", baseImageURI, "\",",
                "\"attributes\":[",
                    "{\"trait_type\":\"Items\",\"value\":\"", Strings.toString(count), "\"},",
                    "{\"trait_type\":\"Top Terpene\",\"value\":\"", tTerp, "\"},",
                    "{\"trait_type\":\"Top Terpene Score\",\"value\":\"", Strings.toString(tScore), "\"}",
                "]",
            "}"
        );

        return string(abi.encodePacked(
            "data:application/json;base64,",
            Base64.encode(json)
        ));
    }
}
