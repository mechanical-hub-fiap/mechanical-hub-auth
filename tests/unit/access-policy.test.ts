import { describe, expect, it } from 'vitest';
import { normalizePath, resolveAccess } from '../../src/core/domain/access-policy.js';

describe('resolveAccess — rotas publicas', () => {
  it.each([
    ['/auth/login', 'POST'],
    ['/mechanical-hub/service-orders/OS-2026-001', 'GET'],
    ['/mechanical-hub/service-orders/OS-2026-001/approve', 'POST'],
    ['/mechanical-hub/service-orders/OS-2026-001/reject', 'POST'],
    ['/webhooks/payment', 'POST'],
  ])('%s %s nao exige token', (path, method) => {
    expect(resolveAccess(path, method).kind).toBe('PUBLIC');
  });
});

describe('resolveAccess — rotas exclusivas do administrador', () => {
  it.each([
    ['/stock', 'GET'],
    ['/stock/entry', 'POST'],
    ['/stock/11111111-1111-4111-8111-111111111111/movements', 'GET'],
    ['/transaction/11111111-1111-4111-8111-111111111111', 'GET'],
  ])('%s %s exige ADMINISTRATOR', (path, method) => {
    const decision = resolveAccess(path, method);

    expect(decision.kind).toBe('REQUIRES_ROLE');
    if (decision.kind === 'REQUIRES_ROLE') {
      expect(decision.roles).toEqual(['ADMINISTRATOR']);
    }
  });
});

describe('resolveAccess — mecanico e administrador', () => {
  it.each([
    ['/orders', 'POST'],
    ['/orders', 'GET'],
    ['/orders/1', 'GET'],
    ['/orders/1/repairs', 'PATCH'],
    ['/orders/1/status', 'PATCH'],
    ['/orders/status', 'POST'],
    ['/services', 'GET'],
  ])('%s %s aceita mecanico e administrador', (path, method) => {
    const decision = resolveAccess(path, method);

    expect(decision.kind).toBe('REQUIRES_ROLE');
    if (decision.kind === 'REQUIRES_ROLE') {
      expect([...decision.roles].sort()).toEqual(['ADMINISTRATOR', 'MECHANICAL']);
    }
  });

  it('nao confunde a rota publica do cliente com a rota interna', () => {
    expect(resolveAccess('/mechanical-hub/service-orders/1', 'GET').kind).toBe('PUBLIC');
    expect(resolveAccess('/orders/1', 'GET').kind).toBe('REQUIRES_ROLE');
  });
});

describe('resolveAccess — default deny', () => {
  it.each(['/rota-inexistente', '/admin', '/', '/auth', '/auth/register', '/webhooks', '/webhooks/outro'])(
    '%s cai em UNKNOWN_ROUTE',
    (path) => {
      expect(resolveAccess(path, 'GET').kind).toBe('UNKNOWN_ROUTE');
    },
  );

  // Rotas do monolito e de operacao/documentacao que sairam do gateway.
  it.each([
    '/users',
    '/users/register',
    '/customers/1',
    '/vehicles/1',
    '/materials/1',
    '/reports/average-execution-time',
    '/service-orders',
    '/service-orders/1',
    '/actuator/health',
    '/swagger-ui/index.html',
    '/v3/api-docs',
  ])('%s saiu da matriz', (path) => {
    expect(resolveAccess(path, 'GET').kind).toBe('UNKNOWN_ROUTE');
  });

  it.each([
    ['/auth/login', 'GET'],
    ['/webhooks/payment', 'GET'],
    ['/services', 'POST'],
    ['/services/1', 'GET'],
    ['/transaction/1', 'DELETE'],
    ['/transaction/1/history', 'GET'],
  ])('%s %s nao herda a permissao de outro metodo ou caminho', (path, method) => {
    expect(resolveAccess(path, method).kind).toBe('UNKNOWN_ROUTE');
  });
});

describe('normalizePath', () => {
  it('descarta query string e barra final', () => {
    expect(normalizePath('/orders/?status=OPEN')).toBe('/orders');
    expect(normalizePath('/orders/')).toBe('/orders');
    expect(normalizePath('orders')).toBe('/orders');
    expect(normalizePath('/')).toBe('/');
  });
});
