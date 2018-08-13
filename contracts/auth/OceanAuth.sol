pragma solidity 0.4.24;

import '../OceanMarket.sol';

/**
@title Ocean Protocol Authorization Contract
@author Team: Fang Gong, Ahmed Ali, Sebastian Gerske
*/
contract OceanAuth {

    // ============
    // DATA STRUCTURES:
    // ============
    OceanMarket private market;

    // Sevice level agreement published on immutable storage
    struct AccessAgreement {
        string accessAgreementRef;  // reference link or i.e IPFS hash
        string accessAgreementType; // type such as PDF/DOC/JSON/XML file.
    }

    // consent (initial agreement) provides details about the service
    struct Consent {
        bytes32 resourceId;
        string permissions;
        AccessAgreement accessAgreement;
        bool isAvailable;
        uint256 startDate;
        uint256 expirationDate;
        string discovery;
        uint256 timeout;
    }

    struct AccessControlRequest {
        address consumer;
        address provider;
        bytes32 resourceId;
        Consent consent;
        string tempPubKey; // temp public key for access token encryption
        bytes encryptedAccessToken;
        AccessStatus status; // Requested, Committed, Delivered, Revoked
    }

    mapping(bytes32 => AccessControlRequest) private accessControlRequests;

    enum AccessStatus {Requested, Committed, Delivered, Verified, Revoked}

    // ============
    // modifier:
    // ============
    modifier isAccessRequested(bytes32 id) {
        require(accessControlRequests[id].status == AccessStatus.Requested, 'Status not requested.');
        _;
    }

    modifier isAccessCommitted(bytes32 id) {
        require(accessControlRequests[id].status == AccessStatus.Committed, 'Status not Committed.');
        _;
    }
    modifier isAccessDelivered(bytes32 id) {
        require(market.verifyPaymentReceived(id));
        require(accessControlRequests[id].status == AccessStatus.Delivered, 'Status not Delivered.');
        _;
    }

    modifier onlyProvider(bytes32 id) {
        require(accessControlRequests[id].provider == msg.sender, 'Sender is not Provider.');
        _;
    }

    modifier onlyConsumer(bytes32 id) {
        require(accessControlRequests[id].consumer == msg.sender, 'Sender is not consumer.');
        _;
    }

    // ============
    // EVENTS:
    // ============
    event AccessConsentRequested(bytes32 _id, address indexed _consumer, address indexed _provider, bytes32 indexed _resourceId, uint _timeout, string _pubKey);
    event AccessRequestCommitted(bytes32 indexed _id, uint256 _expirationDate, string _discovery, string _permissions, string _accessAgreementRef);
    event AccessRequestRejected(address indexed _consumer, address indexed _provider, bytes32 indexed _id);
    event AccessRequestRevoked(address indexed _consumer, address indexed _provider, bytes32 indexed _id);
    event EncryptedTokenPublished(bytes32 indexed _id, bytes _encryptedAccessToken);
    event AccessRequestDelivered(address indexed _consumer, address indexed _provider, bytes32 indexed _id);

    /**
    * @dev OceanAuth Constructor
    * @param _marketAddress The deployed contract address of Ocean marketplace
    * Runs only on initial contract creation.
    */
    constructor(address _marketAddress) public {
        require(_marketAddress != address(0), 'Market address cannot be 0x0');
        // instance of Market
        market = OceanMarket(_marketAddress);
        // add auth contract to access list in market contract - function in market contract
        market.addAuthAddress();
    }

    /**
    @dev consumer initiates access request of service
    @param resourceId identifier associated with resource
    @param provider provider address of the requested resource
    @param pubKey the temporary public key generated by consumer in local
    @param timeout the expiration time of access request in seconds
    @return valid Boolean indication of if the access request has been submitted successfully
    */
    function initiateAccessRequest(bytes32 resourceId, address provider, string pubKey, uint256 timeout) public returns (bool) {
        // pasing `id` from outside for debugging purpose; otherwise, generate Id inside automatically
        bytes32 id = keccak256(abi.encodePacked(resourceId, msg.sender, provider, pubKey));
        // initialize AccessAgreement, and claim
        AccessAgreement memory accessAgreement = AccessAgreement(new string(0), new string(0));
        Consent memory consent = Consent(resourceId, new string(0), accessAgreement, false, 0, 0, new string(0), timeout);
        // initialize acl handler
        AccessControlRequest memory accessControlRequest = AccessControlRequest(
            msg.sender,
            provider,
            resourceId,
            consent,
            pubKey,
            new bytes(0),
            AccessStatus.Requested
        );

        accessControlRequests[id] = accessControlRequest;
        emit AccessConsentRequested(id, msg.sender, provider, resourceId, timeout, pubKey);
        return true;
    }

    /**
    @dev provider commits the access request of service
    @param id identifier associated with the access request
    @param isAvailable boolean indication of the avaiability of resource
    @param expirationDate the expiration time of access request in seconds
    @param discovery  authorization server configuration in the provider side
    @param permissions comma sparated permissions in one string
    @param accessAgreementRef reference link or i.e IPFS hash
    @param accessAgreementType type such as PDF/DOC/JSON/XML file.
    @return valid Boolean indication of if the access request has been committed successfully
    */
    function commitAccessRequest(bytes32 id, bool isAvailable, uint256 expirationDate, string discovery, string permissions, string accessAgreementRef, string accessAgreementType)
    public onlyProvider(id) isAccessRequested(id) returns (bool) {
        /* solium-disable-next-line */
        if (isAvailable && block.timestamp < expirationDate) {
            accessControlRequests[id].consent.isAvailable = isAvailable;
            accessControlRequests[id].consent.expirationDate = expirationDate;
            /* solium-disable-next-line */
            accessControlRequests[id].consent.startDate = block.timestamp;
            accessControlRequests[id].consent.discovery = discovery;
            accessControlRequests[id].consent.permissions = permissions;
            accessControlRequests[id].status = AccessStatus.Committed;
            AccessAgreement memory accessAgreement = AccessAgreement(
                accessAgreementRef,
                accessAgreementType
            );
            accessControlRequests[id].consent.accessAgreement = accessAgreement;
            emit AccessRequestCommitted(id, expirationDate, discovery, permissions, accessAgreementRef);
            return true;
        }

        // otherwise
        accessControlRequests[id].status = AccessStatus.Revoked;
        emit AccessRequestRejected(accessControlRequests[id].consumer, accessControlRequests[id].provider, id);
        return false;
    }

    // you can cancel consent and do refund only after consumer makes the payment and timeout.
    function cancelAccessRequest(bytes32 id) public isAccessCommitted(id) onlyConsumer(id) {
        // timeout
        /* solium-disable-next-line */
        require(block.timestamp > accessControlRequests[id].consent.timeout, 'Timeout not exceeded.');

        // refund only if consumer had made payment
        if(market.verifyPaymentReceived(id)){
            require(market.refundPayment(id), 'Refund payment failed.');
        }
        // Always emit this event regardless of payment refund.
        accessControlRequests[id].status = AccessStatus.Revoked;
        emit AccessRequestRevoked(accessControlRequests[id].consumer, accessControlRequests[id].provider, id);
    }

    /**
    @dev provider delivers the access token of service to on-chain
    @param id identifier associated with the access request
    @param encryptedAccessToken the encrypted access token of resource
    @return valid Boolean indication of if the access token has been delivered
    */
    function deliverAccessToken(bytes32 id, bytes encryptedAccessToken) public onlyProvider(id) isAccessCommitted(id) returns (bool) {
        accessControlRequests[id].encryptedAccessToken = encryptedAccessToken;
        accessControlRequests[id].status = AccessStatus.Delivered;
        emit EncryptedTokenPublished(id, encryptedAccessToken);
        return true;
    }

    /**
    @dev provider retrieves the temp public key from on-chain
    @param id identifier associated with the access request
    @return the temp public key as string
    */
    function getTempPubKey(bytes32 id) public view onlyProvider(id) isAccessCommitted(id) returns (string) {
        return accessControlRequests[id].tempPubKey;
    }

    /**
    @dev consumer retrieves the encrypted access token from on-chain
    @param id identifier associated with the access request
    @return the encrypted access token as bytes32
    */
    function getEncryptedAccessToken(bytes32 id) public view onlyConsumer(id) isAccessDelivered(id) returns (bytes) {
        return accessControlRequests[id].encryptedAccessToken;
    }

    /**
    @dev provider verifies the signature comes from the consumer
    @param _addr the address of consumer
    @param msgHash the hash of message used for verification
    @param v ECDSA signature is divided into parameters and v is the first part
    @param r ECDSA signature is divided into parameters and r is the second part
    @param s ECDSA signature is divided into parameters and s is the remaining part
    @return valid Boolean indication of if the signature is verified successfully
    */
    function verifySignature(address _addr, bytes32 msgHash, uint8 v, bytes32 r, bytes32 s) public pure returns (bool) {
        return (ecrecover(msgHash, v, r, s) == _addr);
    }

    /**
    @dev provider verify the access token is delivered to consumer and request for payment
    @param id identifier associated with the access request
    @param _addr the address of consumer
    @param msgHash the hash of message used for verification
    @param v ECDSA signature is divided into parameters and v is the first part
    @param r ECDSA signature is divided into parameters and r is the second part
    @param s ECDSA signature is divided into parameters and s is the remaining part
    @return valid Boolean indication of if the signature is verified successfully
    */
    function verifyAccessTokenDelivery(bytes32 id, address _addr, bytes32 msgHash, uint8 v, bytes32 r, bytes32 s) public
    onlyProvider(id) isAccessDelivered(id) returns (bool) {
        // verify signature from consumer
        if (verifySignature(_addr, msgHash, v, r, s)) {
            // send money to provider
            require(market.releasePayment(id), 'Release payment failed.');
            // change status of Request
            accessControlRequests[id].status = AccessStatus.Verified;
            // emit an event
            emit AccessRequestDelivered(accessControlRequests[id].consumer, accessControlRequests[id].provider, id);
            return true;
        } else {
            accessControlRequests[id].status = AccessStatus.Revoked;
            require(market.refundPayment(id), 'Refund payment failed.');
            emit AccessRequestRevoked(accessControlRequests[id].consumer, accessControlRequests[id].provider, id);
            return false;
        }
    }

    /**
    @dev Get status of an access request.
    @param id identifier associated with the access request
    @return integer representing status of `AccessStatus {Requested, Committed, Delivered, Revoked}` as uint8
    */
    function statusOfAccessRequest(bytes32 id) public view returns (uint8) {
        return uint8(accessControlRequests[id].status);
    }

}
